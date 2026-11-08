#!/usr/bin/env python3
"""Reject unversioned or incorrectly identified app bundles before packaging."""
import argparse
import plistlib
import re
from pathlib import Path


def validate(info, expected_identifier):
    if info.get('CFBundleIdentifier') != expected_identifier:
        raise ValueError('unexpected app bundle identifier')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        value = info.get(key)
        if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value):
            raise ValueError(f'{key} must contain a resolved numeric version')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('plist', type=Path)
    parser.add_argument('identifier')
    args = parser.parse_args()
    validate(plistlib.loads(args.plist.read_bytes()), args.identifier)
    print('App identity and version metadata verified')
