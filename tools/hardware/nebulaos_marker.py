"""The OTA marker: exact read, exact set, and an honest INDETERMINATE.

WHAT THE MARKER IS

/dev/mmcblk0p1 holds one of two strings that tell the vendor bootloader which
slot to boot next:

    ota:kernel    -> slot 1 (kernel p5, rootfs p7) - Creality's from the factory
    ota:kernel2   -> slot 2 (kernel2 p6, rootfs2 p8) - NebulaOS's original home

Since 2026-10-14 NebulaOS may occupy either or both slots, so a marker names a
SLOT, not an OS. What a slot holds is nebulaos_slots' question, answered from
the device; this module only owns the bytes.

This module owns the byte format and the parse. It performs no I/O: a caller
hands it 512 bytes read from the device and gets back a state, or asks it for
the exact bytes to write. That split is deliberate - it makes every rule here
testable without a printer, and it means the on-device transport cannot
accidentally reinterpret a marker.

THE PREFIX TRAP

"ota:kernel" is a prefix of "ota:kernel2". Any parse built on
`startswith("ota:kernel")` reports STOCK for a device that is actually set to
boot NebulaOS. That single mistake would make an installer reboot into the slot
it just decided not to boot, so the parse below never matches a bare prefix: it
matches the full token AND the terminator that follows it, and it checks the
longer token first.

WHY TWO TERMINATORS ARE VALID, AND WHY THAT IS NOT LOOSENESS

Two different writers produce this marker on a real device, and they disagree by
one byte:

    Creality's stock ota_utils.sh  mmc_write_str: `echo $str > $dev`  -> "ota:kernel\\n"
    NebulaOS's /etc/ota_marker.sh  printf '%s\\n\\n'                    -> "ota:kernel\\n\\n"

and ballaswag/ingenic-usbboot checks `strncmp(ota, "ota:kernel\\n", 11)`, which
accepts either. A parser that demanded "\\n\\n" would call a perfectly
well-defined stock-written marker INDETERMINATE, and the installer would then
refuse to reboot a device whose state was never actually in doubt.

So both forms are accepted - as an ENUMERATED SET, not as a prefix match or a
strip(). Anything outside that set is INDETERMINATE. Writing always emits the
canonical two-newline form, so a marker this project wrote is unambiguous even
though it tolerates the other one on read.

INDETERMINATE IS A RESULT, NOT AN ERROR

It means "the next boot target cannot be predicted from these bytes". The only
correct response is to refuse to reboot. Guessing, defaulting, or retrying a
blind toggle are all ways of turning an unknown state into a coin flip on which
OS comes up - and one of those faces auto-flashes the MCU.

CREALITY'S TOGGLE IS NEVER USED AUTONOMOUSLY

From stock, `local_set_next_boot_device` takes no argument: it flips to whatever
the marker currently is not. That is unusable for automation, because the caller
cannot state an intent and the return value does not say where it landed. This
module only ever expresses "set kernel" or "set kernel2", and the transport that
executes it verifies by reading the bytes back.
"""

SECTOR = 512
TOKEN_KERNEL = b"ota:kernel"
TOKEN_KERNEL2 = b"ota:kernel2"

# The accepted terminators, as an explicit set. Longest token first when
# matching, so "ota:kernel2" can never be read as "ota:kernel" + junk.
_ACCEPTED_TERMINATORS = (b"\n\n", b"\n")

KERNEL = "ota:kernel"
KERNEL2 = "ota:kernel2"
INDETERMINATE = "INDETERMINATE"

# Which slot each state selects, for callers that reason about slots.
SLOT_OF = {KERNEL: 1, KERNEL2: 2}


class MarkerError(Exception):
    """A marker operation this module refuses to perform."""


def canonical(state):
    """The exact 512 bytes to write for `state`.

    Always the two-newline form, matching /etc/ota_marker.sh and
    ballaswag/ingenic-usbboot's swap_ota_partition(), and verified byte-for-byte
    against a live device dump:

        6f 74 61 3a 6b 65 72 6e 65 6c 0a 0a 00 00 ...
    """
    if state == KERNEL:
        token = TOKEN_KERNEL
    elif state == KERNEL2:
        token = TOKEN_KERNEL2
    else:
        raise MarkerError(
            "refusing to produce marker bytes for %r. The only writable states are %r and %r - "
            "there is no canonical representation of an indeterminate marker."
            % (state, KERNEL, KERNEL2))
    block = bytearray(SECTOR)
    body = token + b"\n\n"
    block[:len(body)] = body
    return bytes(block)


def parse(block):
    """Classify 512 bytes read from the marker partition.

    Returns (state, reason). `state` is KERNEL, KERNEL2 or INDETERMINATE;
    `reason` explains an INDETERMINATE precisely enough to act on.
    """
    if not isinstance(block, (bytes, bytearray)):
        raise MarkerError("marker block must be bytes, got %s" % type(block).__name__)
    block = bytes(block)

    if len(block) < SECTOR:
        return INDETERMINATE, ("short read: %d bytes, expected at least %d. A partial read of "
                               "the marker is not evidence of its contents." % (len(block), SECTOR))
    block = block[:SECTOR]

    # Longest token first. Reversing this order is the prefix trap.
    for state, token in ((KERNEL2, TOKEN_KERNEL2), (KERNEL, TOKEN_KERNEL)):
        if not block.startswith(token):
            continue
        rest = block[len(token):]
        for terminator in _ACCEPTED_TERMINATORS:
            if not rest.startswith(terminator):
                continue
            padding = rest[len(terminator):]
            if padding.strip(b"\x00"):
                first = next(i for i, b in enumerate(padding) if b)
                return INDETERMINATE, (
                    "%s followed by %r, but byte %d of the padding is 0x%02x rather than NUL. "
                    "Trailing junk means something other than a clean marker write touched this "
                    "partition." % (token.decode(), terminator, len(token) + len(terminator) + first,
                                    padding[first]))
            return state, "exact match: %r + %r + NUL padding" % (token.decode(), terminator)

        return INDETERMINATE, (
            "%s is present but is followed by %r, which is not one of the accepted terminators "
            "%r. A bare token with no newline is what `echo -n` produces and is NOT what either "
            "writer emits." % (token.decode(), rest[:4], _ACCEPTED_TERMINATORS))

    if not block.strip(b"\x00"):
        return INDETERMINATE, "the marker partition is entirely zero - no slot has been selected"

    return INDETERMINATE, (
        "does not begin with %r or %r. First 16 bytes: %r"
        % (TOKEN_KERNEL2.decode(), TOKEN_KERNEL.decode(), block[:16]))


def is_armed_for_stock(state):
    """True when the marker selects slot 1.

    Named rather than compared inline because, on the PRESERVE_STOCK path
    (Creality in slot 1, NebulaOS running from slot 2), 'the marker says
    kernel' and 'this device is armed to boot Creality's slot, which
    auto-flashes the MCU on a power cycle' are the same fact. With NebulaOS in
    slot 1 they are not: callers that may see that state ask nebulaos_slots
    what the selected slot holds.
    """
    return state == KERNEL


def describe(state, reason=""):
    lines = ["OTA_MARKER_STATE=%s" % state]
    if state in SLOT_OF:
        lines.append("OTA_MARKER_SLOT=%d" % SLOT_OF[state])
    else:
        lines.append("OTA_MARKER_SLOT=unknown")
    lines.append("OTA_MARKER_REBOOT_SAFE=%s" % ("YES" if state in SLOT_OF else "NO"))
    if reason:
        lines.append("OTA_MARKER_REASON=%s" % reason)
    return "\n".join(lines)


def verify_readback(written_state, readback_block):
    """Confirm a write landed, by comparing physical bytes to the canonical form.

    Stricter than parse(): a write this project performed must produce EXACTLY
    the canonical bytes. Accepting the single-newline form here would mean
    accepting that something else wrote the partition between our write and our
    read.
    """
    expected = canonical(written_state)
    actual = bytes(readback_block)[:SECTOR]
    if actual == expected:
        return True, "read-back matches the canonical %s block exactly" % written_state
    state, reason = parse(actual)
    if state == written_state:
        return False, (
            "read-back parses as %s but is not byte-identical to what was written (%s). "
            "Something else wrote this partition; refusing to treat the write as verified."
            % (state, reason))
    return False, (
        "wrote %s but the device now reads %s (%s). The write did not land."
        % (written_state, state, reason))
