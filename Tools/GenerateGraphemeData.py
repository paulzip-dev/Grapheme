"""
Copyright (c) 2026 Paul Scott

Generates the Unicode data used by P_Grapheme and its conformance tests.

Usage:  python Tools/GenerateGraphemeData.py [ucd_dir]

  ucd_dir  Directory holding (or to receive) the Unicode data files. Defaults to Tools/ucd.
           Missing files are downloaded from https://www.unicode.org/Public/UCD/latest/ucd/

Reads:   GraphemeBreakProperty.txt, emoji-data.txt, DerivedCoreProperties.txt, GraphemeBreakTest.txt
Writes:  - the block between the GENERATED markers in P_Grapheme.sql (run-length encoded property table)
         - the UNICODE_VERSION constant in P_Grapheme.sql
         - the block between the GENERATED markers in UnitTests/P_UT_Grapheme_Conformance.sql

Packed property value per code point (see P_Grapheme.sql):
  bits 0-3  Grapheme_Cluster_Break  (0 Other, 1 CR, 2 LF, 3 Control, 4 Extend, 5 ZWJ, 6 RI, 7 Prepend,
                                     8 SpacingMark, 9 L, 10 V, 11 T, 12 LV, 13 LVT)
  bit  4    Extended_Pictographic
  bits 5-6  Indic_Conjunct_Break  (0 None, 1 Consonant, 2 Linker, 3 Extend)
"""
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE_URL = 'https://www.unicode.org/Public/UCD/latest/ucd/'
FILES = {
  'GraphemeBreakProperty.txt': 'auxiliary/GraphemeBreakProperty.txt',
  'emoji-data.txt': 'emoji/emoji-data.txt',
  'DerivedCoreProperties.txt': 'DerivedCoreProperties.txt',
  'GraphemeBreakTest.txt': 'auxiliary/GraphemeBreakTest.txt',
}
GCB = {
  'CR': 1, 'LF': 2, 'Control': 3, 'Extend': 4, 'ZWJ': 5, 'Regional_Indicator': 6, 'Prepend': 7,
  'SpacingMark': 8, 'L': 9, 'V': 10, 'T': 11, 'LV': 12, 'LVT': 13,
}
INCB = {'Consonant': 1, 'Linker': 2, 'Extend': 3}
EXTPICT_BIT = 0x10
INCB_SHIFT = 5
MAX_CP = 0x10FFFF
CHUNK_CHARS = 1800  # keeps every generated source line comfortably short


def fetch(ucd_dir):
  os.makedirs(ucd_dir, exist_ok=True)
  for name, path in FILES.items():
    target = os.path.join(ucd_dir, name)
    if not os.path.exists(target):
      print('Downloading', name)
      urllib.request.urlretrieve(BASE_URL + path, target)


def read_ranges(path, wanted_property=None):
  """Yields (first, last, property) for each data line of a UCD file (property = field 2 or field 3)."""
  pattern = re.compile(r'^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*([^;#\s]+)\s*(?:;\s*([^;#\s]+))?')
  with open(path, encoding='utf-8') as f:
    for line in f:
      m = pattern.match(line)
      if not m:
        continue
      first = int(m.group(1), 16)
      last = int(m.group(2), 16) if m.group(2) else first
      yield first, last, m.group(3), m.group(4)


def build_properties(ucd_dir):
  props = bytearray(MAX_CP + 1)

  for first, last, name, _ in read_ranges(os.path.join(ucd_dir, 'GraphemeBreakProperty.txt')):
    for cp in range(first, last + 1):
      props[cp] |= GCB[name]

  for first, last, name, _ in read_ranges(os.path.join(ucd_dir, 'emoji-data.txt')):
    if name == 'Extended_Pictographic':
      for cp in range(first, last + 1):
        props[cp] |= EXTPICT_BIT

  for first, last, name, value in read_ranges(os.path.join(ucd_dir, 'DerivedCoreProperties.txt')):
    if name == 'InCB' and value in INCB:
      for cp in range(first, last + 1):
        props[cp] |= INCB[value] << INCB_SHIFT

  # Surrogates are not scalar values; a lone surrogate must never glue to its neighbours, so treat it as Control.
  for cp in range(0xD800, 0xE000):
    if props[cp] & 0x0F == 0:
      props[cp] |= GCB['Control']
  return props


def unicode_version(ucd_dir):
  with open(os.path.join(ucd_dir, 'GraphemeBreakProperty.txt'), encoding='utf-8') as f:
    m = re.search(r'GraphemeBreakProperty-(\d+\.\d+\.\d+)', f.readline())
  return m.group(1)


def run_length_encode(props):
  runs = []
  prev = None
  for cp, value in enumerate(props):
    if value != prev:
      runs.append((cp, value))
      prev = value
  return runs


def chunk_entries(entries):
  chunks, current, size = [], [], 0
  for entry in entries:
    if size + len(entry) + 1 > CHUNK_CHARS and current:
      chunks.append(','.join(current))
      current, size = [], 0
    current.append(entry)
    size += len(entry) + 1
  if current:
    chunks.append(','.join(current))
  return chunks


def splice(path, begin_marker, end_marker, body):
  with open(path, encoding='utf-8', newline='') as f:
    text = f.read()
  eol = '\r\n' if '\r\n' in text else '\n'
  pattern = re.compile(r'(?<=' + re.escape(begin_marker) + r')[\s\S]*?(?=[ \t]*' + re.escape(end_marker) + r')')
  if not pattern.search(text):
    sys.exit('Markers not found in ' + path)
  text = pattern.sub(lambda _: eol + body.replace('\n', eol) + eol, text, count=1)
  with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text)


def write_package_data(props, version):
  entries = ['%X=%02X' % (cp, value) for cp, value in run_length_encode(props)]
  lines = ["  AddRuns('%s');" % chunk for chunk in chunk_entries(entries)]
  path = os.path.join(ROOT, 'P_Grapheme.sql')
  splice(path, '-- BEGIN GENERATED UNICODE DATA', '-- END GENERATED UNICODE DATA', '\n'.join(lines))
  with open(path, encoding='utf-8', newline='') as f:
    text = f.read()
  text = re.sub(r"(UNICODE_VERSION\s+constant varchar2\(20\) := ')[^']*(')", r'\g<1>' + version + r'\g<2>', text)
  with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(text)
  print('P_Grapheme.sql: %d runs, Unicode %s' % (len(entries), version))


def write_conformance_data(ucd_dir):
  """GraphemeBreakTest.txt line:  ÷ 0020 × 0308 ÷ 0020 ÷   ->  '0020.0308/0020' ('/' break, '.' no break)."""
  cases = []
  with open(os.path.join(ucd_dir, 'GraphemeBreakTest.txt'), encoding='utf-8') as f:
    for line in f:
      line = line.split('#')[0].strip()
      if not line:
        continue
      tokens = line.split()
      # tokens alternate: break-marker, code point, break-marker, ..., break-marker
      encoded = ''
      for token in tokens[1:-1]:
        if token == '÷':
          encoded += '/'
        elif token == '×':
          encoded += '.'
        else:
          encoded += token
      cases.append(encoded)
  lines = ["  AddCases('%s');" % chunk for chunk in chunk_entries(cases)]
  path = os.path.join(ROOT, 'UnitTests', 'P_UT_Grapheme_Conformance.sql')
  splice(path, '-- BEGIN GENERATED CASES', '-- END GENERATED CASES', '\n'.join(lines))
  print('P_UT_Grapheme_Conformance.sql: %d cases' % len(cases))


def main():
  ucd_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'Tools', 'ucd')
  fetch(ucd_dir)
  props = build_properties(ucd_dir)
  write_package_data(props, unicode_version(ucd_dir))
  write_conformance_data(ucd_dir)


if __name__ == '__main__':
  main()
