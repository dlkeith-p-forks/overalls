"""Run only account management for the bounded synthetic PAM helper fixture."""

import ctypes
import json


def account_status() -> int:
    """@cc [owner:ghuntley,label:verification;security] foreign-linux-pam-account-probe
    The synthetic probe MUST call only PAM account management for its fixed test
    identity, reject every conversation, and return the numeric PAM status.
    It MUST NOT authenticate a password, establish credentials or open a session.
    """
    callback_type = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
    )

    def reject_conversation(
        count: int, messages: int | None, responses: int | None, context: int | None
    ) -> int:
        return 19

    callback = callback_type(reject_conversation)

    class Conversation(ctypes.Structure):
        _fields_ = [("conv", callback_type), ("appdata_ptr", ctypes.c_void_p)]

    conversation = Conversation(callback, None)
    library = ctypes.CDLL("@pam@/lib/libpam.so.0")
    library.pam_start.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.POINTER(Conversation),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    library.pam_start.restype = ctypes.c_int
    library.pam_acct_mgmt.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.pam_acct_mgmt.restype = ctypes.c_int
    library.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.pam_end.restype = ctypes.c_int
    handle = ctypes.c_void_p()
    started: int = library.pam_start(
        b"sshd", b"fixture", ctypes.byref(conversation), ctypes.byref(handle)
    )
    if started != 0:
        raise ValueError("synthetic PAM handle creation failed")
    status = 4
    try:
        status = library.pam_acct_mgmt(handle, 0x8000)
        if not 0 <= status <= 31:
            raise ValueError("invalid PAM account status")
        return status
    finally:
        ended: int = library.pam_end(handle, status)
        if ended != 0:
            raise ValueError("synthetic PAM handle retirement failed")


if __name__ == "__main__":
    print(json.dumps({"status": account_status()}))
