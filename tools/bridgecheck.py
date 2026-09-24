"""The typed ScriptingBridge protocol against the players' own dictionaries.

`ScriptingBridgeProtocols.swift` declares one protocol for both players, so
each typed member is a promise about BOTH apps: a member whose type one player
contradicts is not a nil for that player — ScriptingBridge hands back whatever
the dictionary says, and Swift reads it as the declared type. 0.1.1 declared
`id` as String for Spotify; Music's `id` is an integer, so every Music read
retained the integer as an object pointer and the app died on the first Music
track it saw. The fakes the other suites use cannot see this — they have no
dictionary. This reads the real ones.

A member a player does not declare is fine (the optional read answers nil). A
member a player declares with another type must go through KVC per source, the
way `duration` does.

    python3 tools/bridgecheck.py [path/to/ScriptingBridgeProtocols.swift]
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else \
    REPO / "Sources/NotchApp/Media/ScriptingBridgeProtocols.swift"
PLAYERS = {
    # Music ships with macOS, so its absence is a broken check, not a skip.
    "Music": (Path("/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef"), True),
    "Spotify": (Path("/Applications/Spotify.app/Contents/Resources/Spotify.sdef"), False),
}
CLASS_FOR = {"MediaTrack": "track", "MediaArtwork": "artwork", "MediaPlayerApp": "application"}
# Swift type -> the dictionary types it can honestly read. None marks "any
# enumeration": ScriptingBridge returns a four-char code as an integer.
ACCEPTS = {
    "String": {"text"},
    "Int": {"integer", None},
    "Double": {"real", "double integer"},
    "Bool": {"boolean"},
    "NSImage": {"picture"},
    "Data": {"any", "raw data"},
    "MediaTrack": {"track"},
}


def members(source):
    """(protocol, member, swift type) for every typed `@objc optional var`."""
    found, protocol = [], None
    for line in source.splitlines():
        start = re.match(r"\s*@objc protocol (\w+)", line)
        if start:
            protocol = start.group(1)
            continue
        if protocol and re.match(r"\s*}", line):
            protocol = None
            continue
        var = re.match(r"\s*@objc optional var (\w+): (\w+)", line)
        if protocol and var:
            found.append((protocol, var.group(1), var.group(2)))
    return found


def words(member):
    """`artworkUrl` -> `artwork url`, the dictionary's spelling."""
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", member).lower()


def dictionary(path):
    """class name -> {property name: type}, inheritance and extensions folded in."""
    root = ET.parse(path).getroot()
    enums = {e.get("name") for e in root.iter("enumeration")}
    own, parent = {}, {}
    for tag in ("class", "class-extension"):
        for cls in root.iter(tag):
            name = cls.get("name") or cls.get("extends")
            props = own.setdefault(name, {})
            if cls.get("inherits"):
                parent[name] = cls.get("inherits")
            for prop in cls.findall("property"):
                kind = prop.get("type")
                if kind is None:
                    first = prop.find("type")
                    kind = first.get("type") if first is not None else "any"
                props[prop.get("name")] = None if kind in enums else kind

    def resolved(name, seen=()):
        props = {}
        if name in parent and parent[name] not in seen:
            props.update(resolved(parent[name], seen + (name,)))
        props.update(own.get(name, {}))
        return props
    return resolved


failures, checked = [], 0
typed = members(SOURCE.read_text())
assert typed, f"no typed members found in {SOURCE} — the parser no longer matches it"
for player, (path, required) in PLAYERS.items():
    if not path.exists():
        assert not required, f"{player}'s dictionary is missing at {path}"
        print(f"bridgecheck: {player} is not installed here; its dictionary was not checked")
        continue
    lookup = dictionary(path)
    for protocol, member, swift in typed:
        accepts = ACCEPTS.get(swift)
        if accepts is None:
            failures.append(f"{protocol}.{member}: Swift type {swift} has no mapping here — add one")
            continue
        declared = lookup(CLASS_FOR[protocol])
        if words(member) not in declared:
            continue
        checked += 1
        kind = declared[words(member)]
        if kind not in accepts:
            failures.append(
                f"{protocol}.{member} is read as {swift}, but {player} declares "
                f"'{words(member)}' as {kind or 'an enumeration'} — a typed read hands the "
                f"bridge a value of the wrong kind; read it through KVC per source, like duration")

if failures:
    print("bridgecheck: FAILED")
    for failure in failures:
        print("  " + failure)
    sys.exit(1)
print(f"bridgecheck: all checks passed ({checked} typed reads against the players' dictionaries)")
