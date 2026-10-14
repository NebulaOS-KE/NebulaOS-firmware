"""Enrolled device profiles: who the printer is, and how to reach it safely.

WHY PROFILES EXIST OUTSIDE GIT

Three kinds of thing live here, and none of them belongs in a repository:

  * per-unit physical identity (eMMC CID, SHA-256 of the sn_mac partition)
  * per-OS SSH host keys, pinned
  * credential references and the credentials themselves

The first is device-specific and would be meaningless to anyone else. The second
and third are secrets. So the store is:

    ~/.config/nebulaos-hardware/devices/<device-id>/

with the same hygiene the attestation key gets: directory 0700, files 0600,
regular files only (lstat, so a planted symlink is refused rather than
followed), owned by the invoking user.

ENROLMENT IS A HUMAN ACT

This module READS profiles. It has no create() and no update-on-the-fly path,
because the moment an installer can enrol a device it can also enrol the wrong
one - and "first contact, record whatever answered" is precisely how a machine
that moved onto a remembered DHCP lease gets flashed.

A human creates the directory, records the identity from a device they have
physically confirmed, and pins the host keys. tools/hardware/enroll-device.sh
walks through it. That script is deliberately NOT in the set of launchers an
agent may run.

STRICT HOST KEYS, NO TOFU, NO REPINNING

Each profile pins a host key PER OS, because the stock slot and the NebulaOS
slot are different systems with different keys on the same physical printer.
Addressing the device while it runs stock uses the stock key; addressing it
while it runs NebulaOS uses the NebulaOS key. A key that does not match is a
refusal - never a prompt, never an automatic re-pin. If a key legitimately
changed (a reflash, a regenerated host key), a human re-enrols it.

AN ADDRESS IS NOT AN IDENTITY

The profile records address HISTORY per OS, which is a hint for rediscovery
after a reboot or a lease change - a list of places to look, in order. It is
never proof. Whatever answers is checked against the pinned physical identity
before anything destructive happens.
"""

import hashlib
import os
import stat

DEFAULT_HOME = os.path.join(os.path.expanduser("~"), ".config", "nebulaos-hardware")

# Overridable so the test suite can point at a fixture tree. Production callers
# never set it; the launcher does not forward it.
ENV_HOME = "NEBULAOS_HARDWARE_HOME"

OS_NEBULAOS = "nebulaos"
OS_STOCK = "stock"


class ProfileError(Exception):
    """A profile that is missing, malformed, or not safe to use."""


def hardware_home():
    return os.environ.get(ENV_HOME) or DEFAULT_HOME


def devices_dir():
    return os.path.join(hardware_home(), "devices")


def _check_mode(path, want, label):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        raise ProfileError("%s does not exist: %s" % (label, path))
    except OSError as exc:
        raise ProfileError("cannot stat %s (%s): %s" % (label, path, exc))
    if stat.S_ISLNK(st.st_mode):
        raise ProfileError(
            "%s is a symlink: %s. Refusing to follow it - a symlink here lets whoever can "
            "create one choose which identity or credential gets used." % (label, path))
    if st.st_uid != os.geteuid():
        raise ProfileError("%s is owned by uid %d, not by the invoking user" % (label, st.st_uid))
    mode = stat.S_IMODE(st.st_mode)
    if mode != want:
        raise ProfileError("%s has mode %04o, expected exactly %04o: %s"
                           % (label, mode, want, path))
    return st


def _read_kv(path, label):
    _check_mode(path, 0o600, label)
    fields = {}
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ProfileError("%s line %d is not KEY=VALUE: %r" % (path, lineno, raw))
            key, _, value = line.partition("=")
            key = key.strip()
            if key in fields:
                raise ProfileError("%s defines %s more than once" % (path, key))
            fields[key] = value.strip()
    return fields


class DeviceProfile:
    """One enrolled printer."""

    REQUIRED = ("DEVICE_ID", "EMMC_CID", "SN_MAC_SHA256",
                "NEBULAOS_HOST_KEY", "STOCK_HOST_KEY")

    def __init__(self, device_id, root, fields):
        self.device_id = device_id
        self.root = root
        self.fields = fields

    # -- loading -----------------------------------------------------------
    @classmethod
    def load(cls, device_id):
        if not device_id or not all(c.isalnum() or c in "-_" for c in device_id):
            raise ProfileError(
                "device id %r must be non-empty and contain only letters, digits, '-' and '_'. "
                "It names a directory, so anything else is a path traversal waiting to happen."
                % device_id)
        base = devices_dir()
        _check_mode(hardware_home(), 0o700, "the hardware profile home")
        _check_mode(base, 0o700, "the devices directory")
        root = os.path.join(base, device_id)
        _check_mode(root, 0o700, "the device profile directory")

        fields = _read_kv(os.path.join(root, "profile.conf"), "the device profile")
        missing = [k for k in cls.REQUIRED if not fields.get(k)]
        if missing:
            raise ProfileError(
                "profile for %s is missing required field(s): %s. An incomplete profile cannot "
                "prove which printer this is." % (device_id, ", ".join(missing)))
        if fields["DEVICE_ID"] != device_id:
            raise ProfileError("profile says DEVICE_ID=%s but lives in directory %s"
                               % (fields["DEVICE_ID"], device_id))
        return cls(device_id, root, fields)

    @classmethod
    def list_enrolled(cls):
        base = devices_dir()
        if not os.path.isdir(base):
            return []
        return sorted(d for d in os.listdir(base)
                      if os.path.isdir(os.path.join(base, d)))

    # -- identity ----------------------------------------------------------
    def expected_fingerprint(self):
        """The same derivation nebulaos_device.Identity.fingerprint() uses.

        Kept in step by a test that computes both from one set of facts, rather
        than by hoping two hand-written expressions stay equal.
        """
        blob = "|".join([
            "cid=%s" % self.fields["EMMC_CID"],
            "sn_mac=%s" % self.fields["SN_MAC_SHA256"],
        ]).encode("utf-8")
        return hashlib.sha256(blob).hexdigest()

    def identity_matches(self, identity):
        """-> (ok, reason). Compares PHYSICAL signals only."""
        if not identity.is_complete():
            return False, ("the device did not supply a complete identity "
                           "(cid=%r sn_mac=%r) - an unidentified printer is not this printer"
                           % (identity.emmc_cid, identity.sn_mac_sha256))
        if identity.emmc_cid != self.fields["EMMC_CID"]:
            return False, ("eMMC CID mismatch: enrolled %s, answering device %s"
                           % (self.fields["EMMC_CID"], identity.emmc_cid))
        if identity.sn_mac_sha256 != self.fields["SN_MAC_SHA256"]:
            return False, ("sn_mac digest mismatch: enrolled %s, answering device %s"
                           % (self.fields["SN_MAC_SHA256"], identity.sn_mac_sha256))
        return True, "eMMC CID and sn_mac digest both match the enrolled profile"

    # -- per-OS access -----------------------------------------------------
    def host_key(self, which_os):
        key = self.fields.get("%s_HOST_KEY" % which_os.upper())
        if not key:
            raise ProfileError("no pinned host key for %s in profile %s" % (which_os, self.device_id))
        return key

    def address_history(self, which_os):
        raw = self.fields.get("%s_ADDRESS_HISTORY" % which_os.upper(), "")
        return [a.strip() for a in raw.split(",") if a.strip()]

    def username(self, which_os):
        return self.fields.get("%s_USERNAME" % which_os.upper(), "root")

    def credential(self, which_os):
        """Read the credential for one OS from its own 0600 file.

        A reference in profile.conf, contents in a separate file, so the profile
        can be read for diagnostics without the secret coming with it.
        """
        ref = self.fields.get("%s_CREDENTIAL_REF" % which_os.upper())
        if not ref:
            raise ProfileError("no credential reference for %s in profile %s"
                               % (which_os, self.device_id))
        if "/" in ref or ref.startswith("."):
            raise ProfileError("credential reference %r must be a plain filename" % ref)
        path = os.path.join(self.root, ref)
        _check_mode(path, 0o600, "the %s credential" % which_os)
        with open(path, "r", encoding="utf-8") as fh:
            secret = fh.read().rstrip("\n")
        if not secret:
            raise ProfileError("the %s credential at %s is empty" % (which_os, path))
        return secret

    def write_known_hosts(self, which_os, address, out_path):
        """Materialise a private known_hosts holding ONLY the pinned key.

        One address, one key, nothing else - so ssh with
        StrictHostKeyChecking=yes has exactly one thing it can accept. Writing a
        fresh file per connection also means a key we never pinned cannot have
        been appended to it by an earlier accept-new.
        """
        key = self.host_key(which_os)
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (address, key))
        return out_path

    def last_known_good(self):
        return {
            "source_head": self.fields.get("LAST_KNOWN_GOOD_SOURCE_HEAD", ""),
            "ximage_sha256": self.fields.get("LAST_KNOWN_GOOD_XIMAGE_SHA256", ""),
            "rootfs_sha256": self.fields.get("LAST_KNOWN_GOOD_ROOTFS_SHA256", ""),
        }

    def install_mode(self):
        """INSTALL_MODE from the HUMAN-OWNED profile: 'dev' or 'release'.

        Absent means release - the stronger path. An agent cannot select dev:
        the profile store is denied to agents, so only the human who enrolled
        this printer as the development printer can mark it so.
        """
        mode = (self.fields.get("INSTALL_MODE") or "release").strip().lower()
        if mode not in ("dev", "release"):
            raise ProfileError("INSTALL_MODE=%r in the device profile; expected dev or release"
                               % self.fields.get("INSTALL_MODE"))
        return mode

    def other_slot_policy(self):
        """INSTALL_OTHER_SLOT from the HUMAN-OWNED profile: 'preserve' or 'expendable'.

        Whether `install` may overwrite the slot NebulaOS is NOT running from
        when that slot holds something other than NebulaOS - Creality's system,
        or content it cannot identify. Absent means preserve. It is honoured
        only on a DEV device (INSTALL_MODE=dev); see effective_other_slot_policy.
        Since 2026-10-14 NebulaOS may occupy both slots (nebulaos_slots).
        """
        raw = self.fields.get("INSTALL_OTHER_SLOT")
        value = (raw or "preserve").strip().lower()
        if value not in ("preserve", "expendable"):
            raise ProfileError("INSTALL_OTHER_SLOT=%r in the device profile; expected preserve or "
                               "expendable" % raw)
        return value

    def effective_other_slot_policy(self):
        """-> (policy, note): the other-slot policy that applies to an install now."""
        value = self.other_slot_policy()
        if value == "expendable" and self.install_mode() != "dev":
            return "preserve", ("INSTALL_OTHER_SLOT=expendable is ignored on a RELEASE device; "
                                "the other slot is preserved")
        if "INSTALL_OTHER_SLOT" not in self.fields:
            return value, "INSTALL_OTHER_SLOT is not set in the device profile (default preserve)"
        return value, "INSTALL_OTHER_SLOT=%s in the device profile" % value

    def describe(self):
        lines = [
            "DEVICE_ID=%s" % self.device_id,
            "DEVICE_PROFILE_DIR=%s" % self.root,
            "DEVICE_EMMC_CID=%s" % self.fields["EMMC_CID"],
            "DEVICE_SN_MAC_SHA256=%s" % self.fields["SN_MAC_SHA256"],
            "DEVICE_EXPECTED_FINGERPRINT=%s" % self.expected_fingerprint(),
            "DEVICE_HOST_KEY_PINNED_NEBULAOS=%s" % ("YES" if self.fields.get("NEBULAOS_HOST_KEY") else "NO"),
            "DEVICE_HOST_KEY_PINNED_STOCK=%s" % ("YES" if self.fields.get("STOCK_HOST_KEY") else "NO"),
            "DEVICE_HOST_KEY_POLICY=strict (no TOFU, no automatic repinning)",
        ]
        for which in (OS_NEBULAOS, OS_STOCK):
            lines.append("DEVICE_%s_ADDRESS_HISTORY=%s"
                         % (which.upper(), ",".join(self.address_history(which)) or "none"))
        lkg = self.last_known_good()
        lines.append("DEVICE_LAST_KNOWN_GOOD_SOURCE_HEAD=%s" % (lkg["source_head"] or "none"))
        lines.append("DEVICE_INSTALL_OTHER_SLOT=%s" % (self.fields.get("INSTALL_OTHER_SLOT") or "unset (preserve)"))
        return "\n".join(lines)


def candidate_addresses(profile, which_os, extra=()):
    """Where to look for this printer, in order, after a reboot or a lease change.

    History first (most recent first), then anything the caller already knows.
    This is a search ORDER, not a trust decision: every candidate is still
    identity-checked before it is used for anything.

    Deliberately no scanning, no broadcast, no DNS. The set of places this will
    ever speak to is the set a human enrolled.
    """
    seen, out = set(), []
    for addr in list(extra) + profile.address_history(which_os):
        if addr and addr not in seen:
            seen.add(addr)
            out.append(addr)
    return out


def is_private_ipv4(address):
    """RFC1918 dotted quad only. A qualification rig is on a private LAN, and
    refusing everything else means a bad profile cannot reach the internet."""
    parts = address.split(".")
    if len(parts) != 4:
        return False
    try:
        octets = [int(p) for p in parts]
    except ValueError:
        return False
    if any(o < 0 or o > 255 for o in octets) or any(not p.isdigit() for p in parts):
        return False
    a, b = octets[0], octets[1]
    return a == 10 or (a == 192 and b == 168) or (a == 172 and 16 <= b <= 31)
