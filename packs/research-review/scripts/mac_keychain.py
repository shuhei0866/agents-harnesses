"""Narrow macOS generic-password storage for this pack, without secret argv/files.

The operating system may prompt. No access-control or authentication bypass is
requested. Python is the calling application, not an isolated script identity.
"""
import ctypes as C
import re
import sys

from research_review import ContractError, require

SERVICE = "agents-harnesses.research-review"


class MacKeychain:
    def __init__(self):
        require(sys.platform == "darwin", "macOS Keychain is required")
        self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.sec = C.CDLL("/System/Library/Frameworks/Security.framework/Security")
        signatures = {
            "CFStringCreateWithCString": ([C.c_void_p, C.c_char_p, C.c_uint32], C.c_void_p),
            "CFDataCreate": ([C.c_void_p, C.c_void_p, C.c_long], C.c_void_p),
            "CFDataGetLength": ([C.c_void_p], C.c_long),
            "CFDataGetBytePtr": ([C.c_void_p], C.c_void_p),
            "CFDictionaryCreate": ([C.c_void_p, C.POINTER(C.c_void_p),
                                    C.POINTER(C.c_void_p), C.c_long,
                                    C.c_void_p, C.c_void_p], C.c_void_p),
            "CFRelease": ([C.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.cf, name)
            fn.argtypes, fn.restype = args, result
        for name, args in {
            "SecItemAdd": [C.c_void_p, C.c_void_p],
            "SecItemCopyMatching": [C.c_void_p, C.POINTER(C.c_void_p)],
            "SecItemUpdate": [C.c_void_p, C.c_void_p],
            "SecItemDelete": [C.c_void_p],
        }.items():
            fn = getattr(self.sec, name)
            fn.argtypes, fn.restype = args, C.c_int32

    def constant(self, name):
        library = self.cf if name.startswith("kCF") else self.sec
        return C.c_void_p.in_dll(library, name).value

    def query(self, account, extras=None):
        require(isinstance(account, str) and re.fullmatch(r"[a-f0-9]{32}", account),
                "invalid runtime Keychain slot")
        owned = []
        def string(value):
            ptr = self.cf.CFStringCreateWithCString(None, value.encode(), 0x08000100)
            require(bool(ptr), "Keychain allocation failed")
            owned.append(ptr)
            return ptr
        pairs = [(self.constant("kSecClass"), self.constant("kSecClassGenericPassword")),
                 (self.constant("kSecAttrService"), string(SERVICE)),
                 (self.constant("kSecAttrAccount"), string(account))]
        for key, value in (extras or {}).items():
            if isinstance(value, bytes):
                ptr = self.cf.CFDataCreate(None, value, len(value))
                require(bool(ptr), "Keychain allocation failed")
                owned.append(ptr)
            else:
                ptr = self.constant(value)
            pairs.append((self.constant(key), ptr))
        keys = (C.c_void_p * len(pairs))(*(p[0] for p in pairs))
        values = (C.c_void_p * len(pairs))(*(p[1] for p in pairs))
        # Null callbacks: every nonconstant value stays alive through the call.
        query = self.cf.CFDictionaryCreate(None, keys, values, len(pairs), None, None)
        require(bool(query), "Keychain allocation failed")
        return query, owned

    def release(self, query, owned):
        self.cf.CFRelease(query)
        for ptr in owned:
            self.cf.CFRelease(ptr)

    @staticmethod
    def check(status):
        if status:
            # Return only an OSStatus number, never framework/provider strings.
            raise ContractError("Keychain operation failed (OSStatus %d)" % status)

    def put(self, account, raw, replace=False):
        require(isinstance(raw, bytes) and 0 < len(raw) <= 8192, "invalid secret size")
        query, owned = self.query(account, {"kSecValueData": raw})
        try:
            if not replace:
                self.check(self.sec.SecItemAdd(query, None))
            else:
                match, held = self.query(account)
                try:
                    # SecItemUpdate permits only the changed attributes here.
                    key = (C.c_void_p * 1)(self.constant("kSecValueData"))
                    data = self.cf.CFDataCreate(None, raw, len(raw))
                    require(bool(data), "Keychain allocation failed")
                    attrs = self.cf.CFDictionaryCreate(None, key, (C.c_void_p * 1)(data),
                                                       1, None, None)
                    try:
                        require(bool(attrs), "Keychain allocation failed")
                        self.check(self.sec.SecItemUpdate(match, attrs))
                    finally:
                        if attrs:
                            self.cf.CFRelease(attrs)
                        self.cf.CFRelease(data)
                finally:
                    self.release(match, held)
        finally:
            self.release(query, owned)

    def get(self, account):
        query, owned = self.query(account, {"kSecReturnData": "kCFBooleanTrue",
                                            "kSecMatchLimit": "kSecMatchLimitOne"})
        result = C.c_void_p()
        try:
            self.check(self.sec.SecItemCopyMatching(query, C.byref(result)))
            size = self.cf.CFDataGetLength(result)
            require(0 < size <= 8192, "invalid Keychain item size")
            return C.string_at(self.cf.CFDataGetBytePtr(result), size)
        finally:
            if result.value:
                self.cf.CFRelease(result)
            self.release(query, owned)

    def forget(self, account):
        query, owned = self.query(account)
        try:
            self.check(self.sec.SecItemDelete(query))
        finally:
            self.release(query, owned)
