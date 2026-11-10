#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Recover .proto files from the FileDescriptorProtos a binary embeds.

protobuf's C++ runtime keeps every generated file's serialized
FileDescriptorProto in .rodata. Each one starts with field 1 (the file name,
tag 0x0a) and the name ends in ".proto", so they can be found by scanning and
then asking the protobuf parser how much of what follows is a valid descriptor.

    extract_protos.py <binary> <out-dir>
"""
import sys
from pathlib import Path

from google.protobuf import descriptor_pb2 as pb

F = pb.FieldDescriptorProto
SCALARS = {
    F.TYPE_DOUBLE: "double", F.TYPE_FLOAT: "float", F.TYPE_INT64: "int64",
    F.TYPE_UINT64: "uint64", F.TYPE_INT32: "int32", F.TYPE_FIXED64: "fixed64",
    F.TYPE_FIXED32: "fixed32", F.TYPE_BOOL: "bool", F.TYPE_STRING: "string",
    F.TYPE_BYTES: "bytes", F.TYPE_UINT32: "uint32", F.TYPE_SFIXED32: "sfixed32",
    F.TYPE_SFIXED64: "sfixed64", F.TYPE_SINT32: "sint32", F.TYPE_SINT64: "sint64",
}
LABELS = {F.LABEL_OPTIONAL: "optional", F.LABEL_REQUIRED: "required",
          F.LABEL_REPEATED: "repeated"}


def read_varint(buf, pos):
    value = shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7


def descriptor_extent(buf, start):
    """Walk top-level fields of a FileDescriptorProto; stop at the first thing
    that cannot be one. Returns the end offset."""
    pos = start
    while pos < len(buf):
        try:
            tag, after_tag = read_varint(buf, pos)
        except IndexError:
            break
        field, wire = tag >> 3, tag & 7
        # FileDescriptorProto uses fields 1..14; all are length-delimited except
        # the packed-or-not public/weak dependency indices (varint).
        if field == 0 or field > 14:
            break
        if wire == 2:
            length, body = read_varint(buf, after_tag)
            if body + length > len(buf):
                break
            pos = body + length
        elif wire == 0 and field in (10, 11):
            _, pos = read_varint(buf, after_tag)
        else:
            break
    return pos


def find_descriptors(buf):
    found = {}
    pos = 0
    while True:
        hit = buf.find(b".proto", pos)
        if hit < 0:
            break
        pos = hit + 1
        end_of_name = hit + len(b".proto")
        # Walk back to a 0x0a tag whose length byte lands exactly on the name.
        for name_len in range(len(b"x.proto"), 128):
            start = end_of_name - name_len - 2
            if start < 0:
                break
            if buf[start] == 0x0A and buf[start + 1] == name_len:
                end = descriptor_extent(buf, start)
                fd = pb.FileDescriptorProto()
                try:
                    fd.ParseFromString(buf[start:end])
                except Exception:
                    continue
                if fd.name.endswith(".proto") and (fd.message_type or fd.enum_type or fd.service):
                    found.setdefault(fd.name, fd)
                break
    return found


def type_name(field):
    if field.type in SCALARS:
        return SCALARS[field.type]
    return field.type_name  # fully qualified, leading dot


def default_text(field):
    if not field.HasField("default_value"):
        return ""
    value = field.default_value
    if field.type in (F.TYPE_STRING, F.TYPE_BYTES):
        value = '"%s"' % value
    return " [default = %s]" % value


def emit_enum(enum, out, indent):
    pad = "\t" * indent
    out.append(f"{pad}enum {enum.name} {{")
    for value in enum.value:
        out.append(f"{pad}\t{value.name} = {value.number};")
    out.append(f"{pad}}}")


def emit_message(msg, out, indent):
    pad = "\t" * indent
    out.append(f"{pad}message {msg.name} {{")
    for nested in msg.nested_type:
        emit_message(nested, out, indent + 1)
    for enum in msg.enum_type:
        emit_enum(enum, out, indent + 1)
    for field in msg.field:
        out.append(f"{pad}\t{LABELS[field.label]} {type_name(field)} {field.name} = "
                   f"{field.number}{default_text(field)};")
    out.append(f"{pad}}}")


def render(fd):
    out = [f"// Recovered from an embedded FileDescriptorProto: {fd.name}", ""]
    if fd.package:
        out += [f"package {fd.package};", ""]
    for dep in fd.dependency:
        out.append(f'import "{dep}";')
    if fd.dependency:
        out.append("")
    for enum in fd.enum_type:
        emit_enum(enum, out, 0)
        out.append("")
    for msg in fd.message_type:
        emit_message(msg, out, 0)
        out.append("")
    for service in fd.service:
        out.append(f"service {service.name} {{")
        for method in service.method:
            out.append(f"\trpc {method.name} ({method.input_type}) returns ({method.output_type});")
        out.append("}")
        out.append("")
    return "\n".join(out)


def main():
    binary, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    descriptors = find_descriptors(binary.read_bytes())
    for name, fd in sorted(descriptors.items()):
        target = out_dir / Path(name).name
        target.write_text(render(fd))
        print(f"{name}: {len(fd.message_type)} messages, {len(fd.enum_type)} enums")
        # The raw descriptor too, so protoc-free tools can load exact types.
        (out_dir / (Path(name).name + ".desc")).write_bytes(fd.SerializeToString())


if __name__ == "__main__":
    main()
