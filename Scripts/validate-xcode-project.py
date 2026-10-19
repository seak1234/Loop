#!/usr/bin/env python3
"""Validate project identity and local references, beyond plist syntax.

plutil accepts duplicate object dictionary keys; Xcode cannot safely load the
resulting graph. Check definitions before converting to a dictionary.
"""
import collections
import json
from pathlib import Path
import re
import subprocess
import sys


def validate(path):
    source = path.read_text()
    definitions = re.findall(r'^\s*([A-F0-9]{24})(?: /\*[^\n]*?\*/)? = \{(?=\s*isa\s*=)', source, re.M)
    duplicates = [key for key, count in collections.Counter(definitions).items() if count > 1]
    if duplicates:
        raise ValueError("Duplicate project object IDs: " + ", ".join(duplicates))
    project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
    objects = project["objects"]
    if len(definitions) != len(objects):
        raise ValueError("Could not account for every project object definition")

    def reference(owner, field, value, allowed=None):
        target = objects.get(value)
        if target is None:
            raise ValueError(f"{owner}.{field} references missing object {value}")
        if allowed is not None and target.get("isa") not in allowed:
            raise ValueError(f"{owner}.{field} references {target.get('isa')}, expected {sorted(allowed)}")

    reference("project", "rootObject", project["rootObject"], {"PBXProject"})
    for key, obj in objects.items():
        kind = obj["isa"]
        if kind == "PBXBuildFile" and "fileRef" in obj:
            reference(key, "fileRef", obj["fileRef"], {"PBXFileReference", "PBXReferenceProxy", "PBXVariantGroup", "XCVersionGroup"})
        if kind.endswith("BuildPhase"):
            for value in obj.get("files", []):
                reference(key, "files", value, {"PBXBuildFile"})
        if kind in {"PBXGroup", "PBXVariantGroup", "XCVersionGroup"}:
            for value in obj.get("children", []):
                reference(key, "children", value, {"PBXGroup", "PBXVariantGroup", "XCVersionGroup", "PBXFileReference", "PBXReferenceProxy", "PBXFileSystemSynchronizedRootGroup"})
        if kind in {"PBXNativeTarget", "PBXAggregateTarget"}:
            for value in obj.get("buildPhases", []):
                reference(key, "buildPhases", value)
                if not objects[value]["isa"].endswith("BuildPhase"):
                    raise ValueError(f"{key} references a non-build-phase object")
            for value in obj.get("dependencies", []):
                reference(key, "dependencies", value, {"PBXTargetDependency"})
        if kind == "PBXProject":
            reference(key, "mainGroup", obj["mainGroup"], {"PBXGroup"})
            for value in obj["targets"]:
                reference(key, "targets", value, {"PBXNativeTarget", "PBXAggregateTarget"})
    print(f"Validated {len(objects)} project objects: unique IDs and valid local references.")


if __name__ == "__main__":
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "Loop.xcodeproj/project.pbxproj"
    try:
        validate(path)
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
