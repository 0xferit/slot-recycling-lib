## [1.0.4](https://github.com/0xferit/slot-recycling-lib/compare/v1.0.3...v1.0.4) (2026-03-16)

## [1.0.3](https://github.com/0xferit/slot-recycling-lib/compare/v1.0.2...v1.0.3) (2026-03-16)

### ⚠ BREAKING CHANGES

* RecycleConfig underlying type changed from uint16 to
uint256. Three accessor functions removed from the public API.

### Features

* replace packed uint16 config with precomputed uint256 vacancy mask ([8c5ad53](https://github.com/0xferit/slot-recycling-lib/commit/8c5ad53cdb80374a3717126a08846b0b49ce0cc4))

## [1.0.2](https://github.com/0xferit/slot-recycling-lib/compare/v1.0.1...v1.0.2) (2026-03-16)

## [1.0.1](https://github.com/0xferit/slot-recycling-lib/compare/v1.0.0...v1.0.1) (2026-03-16)

### Features

* invariant tests and byte-alignment documentation ([ff51a01](https://github.com/0xferit/slot-recycling-lib/commit/ff51a01b45c13de5372eae60431e585a2dd38441))

## 1.0.0 (2026-03-16)

### Features

* initial release of slot-recycling-lib ([0549330](https://github.com/0xferit/slot-recycling-lib/commit/05493308498dfe53383950bbac7df0161a041ea8))

### Bug Fixes

* distinct errors, bitmask helper, create overflow guard, NatSpec warnings ([025eb4f](https://github.com/0xferit/slot-recycling-lib/commit/025eb4f07dfeb9bc3cdab23083522f97bd84e0c2))
