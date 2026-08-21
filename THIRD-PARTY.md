# Third-party code

## libASPL

`driver/third_party/libASPL` — <https://github.com/gavv/libASPL>, MIT licensed.

libASPL implements the enormous amount of boilerplate an
`AudioServerPlugIn` needs (property dispatch, object graph, HAL bridging) so
that `driver/Driver.cpp` only has to contain the parts specific to Faded.

Vendored rather than fetched at build time so a clone builds offline and the
exact source that produced a given binary is always in the tree. The pinned
revision, and the one-line local change (a version fallback, since a vendored
copy has no git tag to read), are recorded in
`driver/third_party/libASPL/VENDORED.txt`.

libASPL itself includes two Apple sample-code licences covering the
AudioServerPlugIn headers it derives from — see `LICENSE.apple2012` and
`LICENSE.apple2020` in that directory.
