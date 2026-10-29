#!/usr/bin/env python3
"""Local research handoff contract lint. No provider calls or semantic verdicts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

LIMIT = 2 * 1024 * 1024
KINDS = {"fact", "experience", "attributed_explanation", "inference", "unknown"}
UNVERIFIED = ["source_truth", "prose_claim_coverage", "review_independence", "delivery"]


class ContractError(ValueError):
    pass


def require(ok, message):
    if not ok:
        raise ContractError(message)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def bounded_read(path):
    with path.open("rb") as file:
        raw = file.read(LIMIT + 1)
    require(len(raw) <= LIMIT, "input file too large")
    return raw


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def load(path):
    raw = bounded_read(path)
    def no_constant(value):
        raise ContractError("non-finite JSON number")
    bundle = json.loads(raw, object_pairs_hook=unique_pairs, parse_constant=no_constant)
    require(isinstance(bundle, dict) and type(bundle.get("schema_version")) is int
            and bundle["schema_version"] == 1,
            "expected schema_version 1")
    task = bundle.get("task")
    require(isinstance(task, dict), "task must be an object")
    require(isinstance(task.get("id"), str)
            and bool(re.fullmatch(r"[A-Za-z0-9_-]{1,80}", task["id"])),
            "invalid task id")
    for key in ("question", "recipient", "researcher", "period", "timezone"):
        require(nonempty(task.get(key)), "task missing " + key)
    for key in ("allowed_sources", "allowed_actions"):
        string_list(task.get(key), "task." + key, allow_empty=False)
    cap = task.get("max_chars")
    require(cap is None or (type(cap) is int and cap > 0), "invalid max_chars")
    return bundle


def string_list(value, label, allow_empty=True):
    require(isinstance(value, list) and all(nonempty(x) for x in value),
            label + " must be a string list")
    require(len(value) == len(set(value)), label + " contains duplicates")
    require(allow_empty or value, label + " must not be empty")
    return value


def indexed(rows, label):
    require(isinstance(rows, list), label + " must be a list")
    result = {}
    for row in rows:
        require(isinstance(row, dict) and nonempty(row.get("id")), label + " missing id")
        require(row["id"] not in result, label + " duplicate id")
        result[row["id"]] = row
    return result


def timestamp(value, label):
    require(nonempty(value), label + " missing timestamp")
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ContractError(label + " invalid timestamp") from None
    require(dt.tzinfo is not None, label + " requires timezone")


def sha(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def inspect(bundle, directory):
    sources = indexed(bundle.get("sources"), "sources")
    claims = indexed(bundle.get("claims"), "claims")
    artifacts = indexed(bundle.get("artifacts"), "artifacts")
    require(bool(artifacts), "at least one artifact is required")
    for sid, source in sources.items():
        require(nonempty(source.get("url")), sid + " invalid public URL")
        url = urlsplit(source.get("url", ""))
        require(url.scheme in {"http", "https"} and bool(url.hostname)
                and not url.username and not url.password, sid + " invalid public URL")
        for key in ("speaker", "method", "by", "conditions", "published_at"):
            require(nonempty(source.get(key)), sid + " missing " + key)
        timestamp(source.get("retrieved_at"), sid)
        require(source.get("outcome") in {"read", "excerpt_only", "unavailable"},
                sid + " invalid retrieval outcome")
        if source["outcome"] != "unavailable":
            require(nonempty(source.get("excerpt")), sid + " missing excerpt")
    for cid, claim in claims.items():
        for key in ("statement", "speaker", "conditions"):
            require(nonempty(claim.get(key)), cid + " missing " + key)
        require(claim.get("kind") in KINDS, cid + " invalid kind")
        require(claim.get("causal_status") in
                {"not_asserted", "observed", "reported", "inferred", "unknown"},
                cid + " invalid causal_status")
        refs = string_list(claim.get("source_ids"), cid + ".source_ids")
        require(set(refs) <= sources.keys(), cid + " references missing source")
        if claim["kind"] not in {"inference", "unknown"}:
            require(refs, cid + " requires a source")
    required, hashes, lengths = set(), {}, {}
    for aid, artifact in artifacts.items():
        require(nonempty(artifact.get("path")), aid + " missing path")
        path = Path(artifact["path"])
        require(not path.is_absolute(), aid + " path must be relative")
        resolved = (directory / path).resolve()
        require(directory.resolve() in resolved.parents, aid + " path escapes bundle")
        raw = bounded_read(resolved)
        require(bool(raw), aid + " artifact empty")
        lengths[aid] = len(raw.decode("utf-8"))
        hashes[aid] = sha(raw)
        refs = string_list(artifact.get("claim_ids"), aid + ".claim_ids", False)
        unknown = string_list(artifact.get("unknown_claim_ids"), aid + ".unknown_claim_ids")
        require(set(refs) <= claims.keys(), aid + " references missing claim")
        require(set(unknown) <= set(refs), aid + " unknown IDs outside claim_ids")
        require({c for c in refs if claims[c]["kind"] == "unknown"} <= set(unknown),
                aid + " must disclose unknown claims")
        required.update(refs)
        require(artifact.get("kind") in {"report", "appendix"}, aid + " invalid artifact kind")
    require(any(a["kind"] == "report" for a in artifacts.values()), "report is required")
    content = {k: v for k, v in bundle.items() if k != "review"}
    content["artifact_sha256"] = hashes
    digest = sha(json.dumps(content, sort_keys=True, ensure_ascii=False,
                            separators=(",", ":"), allow_nan=False).encode("utf-8"))
    return sources, claims, artifacts, required, hashes, lengths, digest


def lint(bundle, directory):
    sources, claims, artifacts, required, hashes, lengths, digest = inspect(bundle, directory)
    issues = []
    cap = bundle["task"].get("max_chars")
    if cap and sum(lengths[aid] for aid, a in artifacts.items() if a["kind"] == "report") > cap:
        issues.append("combined report exceeds max_chars")
    review = bundle.get("review")
    verified, unknown = [], []
    if not isinstance(review, dict):
        issues.append("missing review")
    else:
        if review.get("target_digest") != digest:
            issues.append("review digest does not match current bundle and artifact bytes")
        require(nonempty(review.get("reviewer")), "reviewer is required")
        if review["reviewer"] == bundle["task"]["researcher"]:
            issues.append("researcher cannot declare their own independent review")
        timestamp(review.get("checked_at"), "review")
        read = string_list(review.get("artifact_ids"), "review.artifact_ids")
        if set(read) != artifacts.keys():
            issues.append("review must cover the submitted report and every appendix")
        items = indexed([{**x, "id": x.get("claim_id")} for x in review.get("items", [])
                         if isinstance(x, dict)], "review.items")
        require(isinstance(review.get("items"), list)
                and len(items) == len(review["items"]), "invalid review.items")
        require(set(items) <= claims.keys(), "review references missing claim")
        for cid in sorted(required):
            item = items.get(cid)
            if not item:
                issues.append(cid + ": missing item-level review")
                continue
            require(nonempty(item.get("note")), cid + " review missing note")
            verdict = item.get("verdict")
            require(verdict in {"verified", "changes_requested", "unverifiable"},
                    cid + " invalid review verdict")
            refs = string_list(item.get("source_ids"), cid + " review.source_ids")
            require(set(refs) <= set(claims[cid]["source_ids"]),
                    cid + " review references a source not in the claim")
            if verdict == "verified":
                if claims[cid]["kind"] not in {"inference", "unknown"} and not refs:
                    issues.append(cid + ": factual review requires source references")
                elif any(sources[s]["outcome"] == "unavailable" for s in refs):
                    issues.append(cid + ": verified review cites an unavailable retrieval")
                else:
                    verified.append(cid)
            elif verdict == "unverifiable" and claims[cid]["kind"] == "unknown":
                unknown.append(cid)
            else:
                issues.append(cid + ": unresolved review; correct or explicitly classify as unknown")
    return {"task_id": bundle["task"]["id"], "structure_only": True,
            "structurally_complete": not issues, "target_digest": digest,
            "required_claim_ids": sorted(required), "verified_claim_ids": verified,
            "disclosed_unknown_claim_ids": unknown, "artifact_sha256": hashes,
            "artifact_chars": lengths, "issues": issues, "not_verified": UNVERIFIED}


def brief(bundle):
    task = bundle["task"]
    contract = Path(__file__).resolve().parents[1] / "references" / "contract.md"
    return ("Research handoff " + task["id"] + "\nRecipient: " + task["recipient"]
            + "\nUse only the following authorized task scope. Return actual files, not previews.\n"
            + json.dumps(task, ensure_ascii=False, indent=2)
            + "\nPreserve attribution, causal uncertainty and conditions in the final prose. "
              "Record neutral search terms, time window, exclusions and material counterevidence. "
              "No account, permission, billing or routine changes. Use existing authorized roles.\n"
            + "Return bundle.json, report.md and any appendices with this exact task ID. "
              "Use a task-specific directory named by this ID; do not overwrite another task's files. "
              "Researcher owns one bundle; reviewer checks the actual report and all appendices.\n\n"
            + contract.read_text(encoding="utf-8"))


def initialize(args):
    directory = Path(args.directory)
    directory.mkdir(mode=0o700, parents=True)
    bundle = {"schema_version": 1, "task": {"id": uuid.uuid4().hex,
              "question": args.question, "recipient": args.recipient, "researcher": "researcher",
              "period": "unspecified: resolve before research", "timezone": "UTC",
              "allowed_sources": ["public web and public X posts"],
              "allowed_actions": ["read public sources", "save research files",
                                  "message existing authorized review roles"],
              "time_budget": None, "max_chars": args.max_chars},
              "sources": [], "claims": [], "artifacts": [{"id": "report", "kind": "report",
              "path": "report.md", "claim_ids": [], "unknown_claim_ids": []}], "review": None}
    for name, text in {"bundle.json": json.dumps(bundle, ensure_ascii=False, indent=2) + "\n",
                       "report.md": "", ".gitignore": "*\n"}.items():
        with os.fdopen(os.open(directory / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600),
                       "w", encoding="utf-8") as file:
            file.write(text)
    return {"created": True, "task_id": bundle["task"]["id"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("directory")
    init.add_argument("--question", required=True)
    init.add_argument("--recipient", required=True)
    init.add_argument("--max-chars", type=int)
    for command in ("brief", "target", "lint"):
        sub.add_parser(command).add_argument("bundle", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "init":
            require(nonempty(args.question) and nonempty(args.recipient), "empty request")
            require(args.max_chars is None or args.max_chars > 0, "invalid max_chars")
            result = initialize(args)
        else:
            bundle = load(args.bundle)
            if args.command == "brief":
                print(brief(bundle))
                return 0
            if args.command == "lint":
                result = lint(bundle, args.bundle.parent)
            else:
                *_, hashes, lengths, digest = inspect(bundle, args.bundle.parent)
                result = {"task_id": bundle["task"]["id"], "target_digest": digest,
                          "artifact_sha256": hashes, "artifact_chars": lengths}
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 1 if result.get("structurally_complete") is False else 0
    except (ContractError, OSError, ValueError, TypeError, KeyError) as exc:
        # Do not echo file contents, provider configuration or untrusted exception text.
        message = str(exc) if isinstance(exc, ContractError) else "invalid or unreadable input"
        print(json.dumps({"structure_only": True, "error": message}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
