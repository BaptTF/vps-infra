"""
Fix: python-telegram-bot 22.6 + httpx 0.28 incompatibility.

httpx 0.28 made HTTPXRequest use __slots__, so PTB 22.6's pattern of
``request.do_request = wrapper`` fails with:
  AttributeError: 'HTTPXRequest' object attribute 'do_request' is read-only

This module is auto-loaded via a .pth file in lazy-packages.
site.addsitedir() processes .pth files early in Hermes bootstrap
(before Telegram connects), so the subclass is in place when needed.

Strategy: subclass HTTPXRequest with an extra slot for the override,
accessed through a property. When do_request is set, it stores the
wrapper in _do_request_override. On get, it returns the override if
present, otherwise falls back to the original.
"""
import sys

from telegram.request import HTTPXRequest as _OrigHTTPXRequest


class HTTPXRequest(_OrigHTTPXRequest):
    __slots__ = ("_do_request_override",)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        object.__setattr__(self, "_do_request_override", None)

    @property
    def do_request(self):
        override = object.__getattribute__(self, "_do_request_override")
        if override is not None:
            # Return the override directly — do NOT wrap via __get__.
            # The adapter's _do_request closure already captures a bound
            # do_request and expects (url, method, ...) args.  Wrapping
            # would inject `self` as an extra first positional, causing
            # "multiple values for argument 'url'".
            return override
        return super().do_request

    @do_request.setter
    def do_request(self, value):
        object.__setattr__(self, "_do_request_override", value)

    @do_request.deleter
    def do_request(self):
        object.__setattr__(self, "_do_request_override", None)


# Replace in the module namespace before adapter imports it
import telegram.request

telegram.request.HTTPXRequest = HTTPXRequest
print(
    "[hermes-telegram-patch] HTTPXRequest patched"
    " for httpx 0.28 + PTB 22.6 compatibility",
    file=sys.stderr,
)
