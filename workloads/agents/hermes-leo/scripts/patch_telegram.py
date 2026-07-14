"""
Monkey-patch: python-telegram-bot 22.6 + httpx 0.28 compatibility fix.

httpx 0.28 made HTTPXRequest use __slots__ without 'do_request' in slots,
so PTB 22.6's ``request.do_request = wrapper`` fails with:
  AttributeError: 'HTTPXRequest' object attribute 'do_request' is read-only

This module is auto-loaded via a .pth file placed in the lazy-packages
directory, which site.addsitedir() processes early in Hermes bootstrap
(before any Telegram connection attempt).

Load order:
  hermes_bootstrap.py:activate_durable_lazy_target()
    → site.addsitedir(/opt/data/lazy-packages)
      → hermes-telegram-fix.pth: ``import patch_telegram``
        → this module patches HTTPXRequest.do_request
"""
import sys


def _patch():
    from telegram.request import HTTPXRequest

    if getattr(HTTPXRequest, "_hermes_do_request_patched", False):
        return

    _orig_do_request = HTTPXRequest.do_request

    # id(request) → callable registry; PTB sets one override per request
    _override_registry = {}

    class _DoRequestDescriptor:
        def __get__(self, obj, objtype=None):
            if obj is None:
                return _orig_do_request
            override = _override_registry.get(id(obj))
            if override is not None:
                import types
                return types.MethodType(override, obj)
            return _orig_do_request.__get__(obj, objtype)

        def __set__(self, obj, value):
            if obj is None:
                raise AttributeError("cannot set class-level do_request")
            _override_registry[id(obj)] = value

        def __delete__(self, obj):
            if obj is None:
                raise AttributeError("cannot delete class-level do_request")
            _override_registry.pop(id(obj), None)

    HTTPXRequest.do_request = _DoRequestDescriptor()
    HTTPXRequest._hermes_do_request_patched = True
    HTTPXRequest._hermes_override_registry = _override_registry
    print(
        "[hermes-telegram-patch] HTTPXRequest.do_request patched"
        " for httpx 0.28 + PTB 22.6 compatibility",
        file=sys.stderr,
    )


_patch()
