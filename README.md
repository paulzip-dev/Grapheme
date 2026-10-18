# P_Grapheme

Copyright (c) 2026 Paul Scott

Unicode extended grapheme cluster support for Oracle PL/SQL, implementing
[UAX #29](https://www.unicode.org/reports/tr29/) (Unicode 18.0.0).

Oracle's `LENGTH`, `SUBSTR` and `INSTR` count code points or UTF-16 units, not what a user sees as a character.
`🧑‍🌾` is one visible character but three code points (`U+1F9D1 U+200D U+1F33E`), so `SUBSTR` can cut a flag, an emoji
sequence or an accented letter in half. `P_Grapheme` counts, slices, truncates and iterates by grapheme cluster instead.

- Works on `VARCHAR2` (AL32UTF8), `NVARCHAR2` (AL16UTF16) and `CLOB`/`NCLOB`
- Pure PL/SQL, no Java or external libraries
- Never raises on malformed data; a lone surrogate is treated as a control character
- Oracle 19c (19.11+)

## Install

Run the build script from SQL*Plus or SQLcl:

```sql
@GraphemeBuild.sql
```

It runs `GraphemeTypes.sql`, then `P_Grapheme.sql`, then `alter type TY_GraphemeIterator compile body;` (the iterator
body compiles with errors until `P_Grapheme` exists). `GraphemeTypes.sql` drops and recreates the six object types, so
the build can be re-run.

## Usage

```sql
select P_Grapheme.GraphemeCount('e' || unistr('\0301') || '🧑‍🌾🇬🇧') from dual;   -- 3
select P_Grapheme.GraphemeAt('🧑‍🌾🇬🇧', 2)                              from dual;   -- 🇬🇧
select P_Grapheme.GraphemeTruncate('🧑‍🌾🇬🇧abc', 2)                     from dual;   -- 🧑‍🌾🇬🇧
```

### Functions

Every function has a `VARCHAR2`/`NVARCHAR2` and a `CLOB` overload.

| Function | Returns |
|---|---|
| `GraphemeCount(pText)` | Number of clusters |
| `GraphemeAt(pText, pIndex)` | The cluster at a 1-based index |
| `GraphemeSubstring(pText, pStart, pLength)` | `SUBSTR` by clusters |
| `GraphemeTruncate(pText, pMaxLength)` | At most `pMaxLength` clusters, never splitting one |
| `GraphemeBoundaries(pText, pUnit)` | Start offset of every cluster, plus the offset just past the end |
| `IsGraphemeBoundary(pText, pOffset, pUnit)` | Whether an offset is a cluster boundary |
| `GraphemeOffset(pText, pIndex, pUnit)` | Offset at which a cluster starts |
| `GraphemeIterator(pText, pUnit)` | One row per cluster (pipelined, for SQL) |
| `GraphemeList(pText, pUnit)` | The same rows as a collection |
| `CodePoints(pText)` | One row per code point, tagged with its cluster (pipelined) |

### Offset units

Offsets are 1-based and expressed in `pUnit`:

| Constant | Unit |
|---|---|
| `UNIT_NATIVE` (default) | What `SUBSTR` uses for the datatype: code points for `VARCHAR2`, UTF-16 units for `NVARCHAR2` and `CLOB` |
| `UNIT_CODEPOINT` | Unicode code points |
| `UNIT_UTF16` | UTF-16 code units (Java, JavaScript, .NET, `DBMS_LOB`) |
| `UNIT_BYTE` | Bytes in the string's own encoding (not available for `CLOB`) |

### Iterating clusters

In SQL:

```sql
select IDX, START_POS, LENGTH, TEXT
from table(P_Grapheme.GraphemeIterator('🧑‍🌾🇬🇧'));
```

In PL/SQL:

```sql
declare
  vIterator TY_GraphemeIterator := TY_GraphemeIterator.New('🧑‍🌾🇬🇧');
  vGrapheme TY_Grapheme;
begin
  while vIterator.HasNext
  loop
    vGrapheme := vIterator.Next;
    dbms_output.put_line(vGrapheme.IDX || ': ' || vGrapheme.TEXT);
  end loop;
end;
/
```

### Breaking a cluster into code points

```sql
select IDX, GRAPHEME_IDX, CODE_POINT, HEX, TEXT
from table(P_Grapheme.CodePoints('🧑‍🌾'));
```

| IDX | GRAPHEME_IDX | CODE_POINT | HEX | TEXT |
|---|---|---|---|---|
| 1 | 1 | 129489 | U+1F9D1 | 🧑 |
| 2 | 1 | 8205 | U+200D | (zero width joiner) |
| 3 | 1 | 127806 | U+1F33E | 🌾 |

### Errors

| Exception | Code | Raised when |
|---|---|---|
| `INDEX_OUT_OF_RANGE` | -20100 | A grapheme index or length is outside the text |
| `INVALID_UNIT` | -20101 | `pUnit` is not a `UNIT_` constant, or is unsupported for the datatype |
| `CLUSTER_TOO_LONG` | -20102 | A cluster is over 2000 characters (the iterator's `TY_Grapheme.TEXT` limit) |

A null or empty text has 0 graphemes.

## Files

| File | Purpose |
|---|---|
| `GraphemeBuild.sql` | Builds everything: types, then package, then recompiles the iterator body |
| `GraphemeTypes.sql` | Object types and collections, in dependency order |
| `P_Grapheme.sql` | The package |
| `Tools/GenerateGraphemeData.py` | Regenerates the Unicode property table and conformance data from the Unicode Character Database |
| `UnitTests/P_UT_Grapheme.sql` | [utPLSQL](https://utplsql.org/) v3 tests |
| `UnitTests/P_UT_Grapheme_Conformance.sql` | Every case of Unicode's `GraphemeBreakTest.txt` |

## Updating the Unicode version

```
python Tools/GenerateGraphemeData.py
```

Downloads the current UCD files into `Tools/ucd`, then rewrites the property table and `UNICODE_VERSION` in
`P_Grapheme.sql` and the case data in the conformance tests. Do not edit the `GENERATED` blocks by hand.

## Running the tests

```sql
exec ut.run('P_UT_Grapheme');
exec ut.run('P_UT_Grapheme_Conformance');
```
