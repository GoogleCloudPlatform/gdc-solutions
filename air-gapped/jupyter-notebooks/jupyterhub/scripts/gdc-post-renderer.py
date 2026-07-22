#!/usr/bin/env python3
import base64
import re
import sys


def patch_structurally(obj_list, yaml_lib):
    """Patches documents structurally using PyYAML objects."""
    patched_docs = []
    for obj in obj_list:
        if not obj or not isinstance(obj, dict):
            patched_docs.append(obj)
            continue

        kind = obj.get("kind")
        name = obj.get("metadata", {}).get("name", "")

        # 1. Target ConfigMap by data content rather than resource name
        if kind == "ConfigMap" and (
            "jupyterhub_config.py" in obj.get("data", {})
            or "z2jh.py" in obj.get("data", {})
        ):
            data = obj.get("data", {})
            for key in ["jupyterhub_config.py", "z2jh.py"]:
                if key in data:
                    content = data[key]
                    b64_content = base64.b64encode(content.encode("utf-8")).decode(
                        "utf-8"
                    )
                    new_key = key.replace(".py", "_base64")
                    data[new_key] = b64_content
                    del data[key]
            patched_docs.append(obj)

        # 2. Target Deployment by checking if it defines the hub container
        elif kind == "Deployment" and any(
            c.get("name") == "hub"
            for c in obj.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("containers", [])
        ):
            containers = (
                obj.get("spec", {})
                .get("template", {})
                .get("spec", {})
                .get("containers", [])
            )
            for container in containers:
                if container.get("name") == "hub":
                    volume_mounts = container.get("volumeMounts", [])
                    new_mounts = []
                    for mount in volume_mounts:
                        subpath = mount.get("subPath", "")
                        # Strip individual subPath mounts pointing to config python scripts
                        if (
                            subpath in ["jupyterhub_config.py", "z2jh.py"]
                            and mount.get("name") == "config"
                        ):
                            continue
                        new_mounts.append(mount)
                    container["volumeMounts"] = new_mounts
            patched_docs.append(obj)
        else:
            patched_docs.append(obj)

    return yaml_lib.safe_dump_all(patched_docs, default_flow_style=False)


def patch_textual_fallback(input_text):
    """Fallback line-by-line and regex parser if PyYAML is not present."""
    documents = input_text.split("\n---\n")
    patched_docs = []

    for doc in documents:
        if not doc.strip():
            continue

        # 1. Target ConfigMap by content signatures (traverses completely empty lines)
        if "kind: ConfigMap" in doc and (
            "jupyterhub_config.py:" in doc or "z2jh.py:" in doc
        ):
            pattern = (
                r"^(  (jupyterhub_config\.py|z2jh\.py):\s*\|\-?\n)((?:    .*\n|\n)*)"
            )
            matches = list(re.finditer(pattern, doc, re.MULTILINE))
            new_doc = doc
            for match in matches:
                full_match = match.group(0)
                key_name = match.group(2)
                content = match.group(3)

                # Un-indent content to base64 encode original code
                lines = content.split("\n")
                cleaned_lines = []
                for line in lines:
                    if line.startswith("    "):
                        cleaned_lines.append(line[4:])
                    elif line == "":
                        cleaned_lines.append("")
                    else:
                        cleaned_lines.append(line)
                raw_content = "\n".join(cleaned_lines)
                b64_content = base64.b64encode(raw_content.encode("utf-8")).decode(
                    "utf-8"
                )

                new_key_name = key_name.replace(".py", "_base64")
                new_block = f"  {new_key_name}: {b64_content}\n"
                new_doc = new_doc.replace(full_match, new_block)
            patched_docs.append(new_doc)

        # 2. Target Deployment by looking for hub container and stripping subPath volumeMounts
        elif (
            "kind: Deployment" in doc
            and ("jupyterhub_config.py" in doc or "z2jh.py" in doc)
            and "name: hub" in doc
        ):
            lines = doc.splitlines()
            new_lines = []
            in_volume_mounts = False
            mount_indent = None
            current_mount_block = []

            for line in lines:
                stripped = line.strip()
                if stripped == "volumeMounts:":
                    in_volume_mounts = True
                    new_lines.append(line)
                    continue

                if in_volume_mounts:
                    if stripped.startswith("-"):
                        current_indent = len(line) - len(line.lstrip())
                        if mount_indent is None:
                            mount_indent = current_indent

                        if current_indent == mount_indent:
                            # Evaluate completed mount block before starting the next
                            if current_mount_block:
                                block_text = "\n".join(current_mount_block)
                                if (
                                    "subPath: jupyterhub_config.py" not in block_text
                                    and "subPath: z2jh.py" not in block_text
                                ):
                                    new_lines.extend(current_mount_block)
                                current_mount_block = []
                            current_mount_block.append(line)
                        else:
                            # Indentation changed: exited volumeMounts block
                            in_volume_mounts = False
                            mount_indent = None
                            if current_mount_block:
                                block_text = "\n".join(current_mount_block)
                                if (
                                    "subPath: jupyterhub_config.py" not in block_text
                                    and "subPath: z2jh.py" not in block_text
                                ):
                                    new_lines.extend(current_mount_block)
                                current_mount_block = []
                            new_lines.append(line)
                    elif (
                        line.startswith(" " * (mount_indent + 1))
                        if mount_indent is not None
                        else False
                    ):
                        current_mount_block.append(line)
                    else:
                        in_volume_mounts = False
                        mount_indent = None
                        if current_mount_block:
                            block_text = "\n".join(current_mount_block)
                            if (
                                "subPath: jupyterhub_config.py" not in block_text
                                and "subPath: z2jh.py" not in block_text
                            ):
                                new_lines.extend(current_mount_block)
                            current_mount_block = []
                        new_lines.append(line)
                else:
                    new_lines.append(line)

            if current_mount_block:
                block_text = "\n".join(current_mount_block)
                if (
                    "subPath: jupyterhub_config.py" not in block_text
                    and "subPath: z2jh.py" not in block_text
                ):
                    new_lines.extend(current_mount_block)

            patched_docs.append("\n".join(new_lines))
        else:
            patched_docs.append(doc)

    return "\n---\n".join(patched_docs)


def main():
    input_text = sys.stdin.read()

    try:
        import yaml

        docs = list(yaml.safe_load_all(input_text))
        if not docs:
            raise ValueError("No documents parsed.")
        output_text = patch_structurally(docs, yaml)
    except Exception:
        # Graceful fallback to stateful line scanner if PyYAML is missing
        output_text = patch_textual_fallback(input_text)

    sys.stdout.write(output_text)


if __name__ == "__main__":
    main()
