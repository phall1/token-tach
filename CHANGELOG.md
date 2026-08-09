# Changelog

## [0.9.6](https://github.com/phall1/token-tach/compare/v0.9.5...v0.9.6) (2026-08-09)


### Bug Fixes

* **projects:** roll worktrees up to their repository, and collapse triplicated helpers ([#19](https://github.com/phall1/token-tach/issues/19)) ([835c73e](https://github.com/phall1/token-tach/commit/835c73e6092514055bb0e0352d7b80012525c188))

## [0.9.5](https://github.com/phall1/token-tach/compare/v0.9.4...v0.9.5) (2026-08-09)


### Bug Fixes

* **release:** await published tag visibility ([#17](https://github.com/phall1/token-tach/issues/17)) ([a8ffdf5](https://github.com/phall1/token-tach/commit/a8ffdf5d87677a46718f4f753a8aec46160674b2))

## [0.9.4](https://github.com/phall1/token-tach/compare/v0.9.3...v0.9.4) (2026-08-09)


### Bug Fixes

* **release:** discover private drafts ([#15](https://github.com/phall1/token-tach/issues/15)) ([4ef5b75](https://github.com/phall1/token-tach/commit/4ef5b756c76716b6a967620ad9ab324831b4b7cf))

## [0.9.3](https://github.com/phall1/token-tach/compare/v0.9.2...v0.9.3) (2026-08-09)


### Bug Fixes

* **release:** publish validated draft targets ([#13](https://github.com/phall1/token-tach/issues/13)) ([c5729ce](https://github.com/phall1/token-tach/commit/c5729ce0ad442a90e046f8aa177bb1e12382b942))

## [0.9.2](https://github.com/phall1/token-tach/compare/v0.9.1...v0.9.2) (2026-08-09)


### Bug Fixes

* **release:** bootstrap tags through drafts ([#11](https://github.com/phall1/token-tach/issues/11)) ([cfc79ca](https://github.com/phall1/token-tach/commit/cfc79ca6ccf6bd2b3070214452d733ab06d7b492))
* **release:** handle missing tag refs ([#10](https://github.com/phall1/token-tach/issues/10)) ([db6f96d](https://github.com/phall1/token-tach/commit/db6f96db8fddd4c3e96ef6883f3af6d03e76d534))

## [0.9.1](https://github.com/phall1/token-tach/compare/v0.9.0...v0.9.1) (2026-08-09)


### Bug Fixes

* harden release automation and OAuth ([#7](https://github.com/phall1/token-tach/issues/7)) ([da08c8a](https://github.com/phall1/token-tach/commit/da08c8a75af24036cbb9afe852d78c29898a775f))
* **release:** continue after artifact publication ([#8](https://github.com/phall1/token-tach/issues/8)) ([80d45c6](https://github.com/phall1/token-tach/commit/80d45c642db241648dd05dbbfbe56a3ac0fd5f77))
* **release:** stop the tag walk deadlocking on SIGPIPE ([#6](https://github.com/phall1/token-tach/issues/6)) ([de71543](https://github.com/phall1/token-tach/commit/de715435d9f5337c6b17a5a5541ee6d7679224f8))

## [0.9.0](https://github.com/phall1/token-tach/compare/v0.8.0...v0.9.0) (2026-08-04)


### Features

* **cli:** query the durable store — history, burn, top, sessions, export ([8c1f480](https://github.com/phall1/token-tach/commit/8c1f480e4405a0b4d434a8efd4884511fa4da66f))
* **core:** add durable append-only usage time series ([370b910](https://github.com/phall1/token-tach/commit/370b910832ed80fc18663b3037e3a1fbba76eb17))
* **core:** add live agent-session roster ([596cf0f](https://github.com/phall1/token-tach/commit/596cf0f3f724719e42c52f088d318d010ab5d6ba))
* **core:** add wall-clock-anchored sample rings ([c5f46c0](https://github.com/phall1/token-tach/commit/c5f46c0cd36e0d8896eb3d8faf51a5587f46df96))
* **dashboard:** responsive flow layout with real time scoping ([8ab4a23](https://github.com/phall1/token-tach/commit/8ab4a2380faba4d26c4ed6a92f58de81f7c58685))
* **engine:** activate the live instrument — sessions, per-agent burn, durable history ([6fa230d](https://github.com/phall1/token-tach/commit/6fa230d08cf95aca967d04059c92aa7b56e9d32f))
* **hud:** add a transparent always-on-top desktop tach ([ad924cb](https://github.com/phall1/token-tach/commit/ad924cb7cb6455d76ee1f89a2853cca08c1c0390))
* **ledger:** add hourly and per-session rollups with bounded retention ([723fe14](https://github.com/phall1/token-tach/commit/723fe1446bb0429b02165aacf981ea48a14a72e5))
* **sdk:** rebase vendored fork onto Native SDK v0.8.0 ([356d306](https://github.com/phall1/token-tach/commit/356d306c467779e9fc8182daec9430fd03a0730c))
* **statefile:** v5 — persist hourly and per-session rollups, gate the backfill ([9f8eec8](https://github.com/phall1/token-tach/commit/9f8eec80a34e8e40092cdbfd3b7023f5aa99bec7))
* **theme:** freeze the token set the instrument redesign needs ([c01fda9](https://github.com/phall1/token-tach/commit/c01fda9797fe57eef94dd2e5f7c875c8077dbab9))
* **view:** rebuild the popover into a full instrument cluster ([2724584](https://github.com/phall1/token-tach/commit/2724584338d33cd418eddca0b7d4b792378b2559))


### Bug Fixes

* **opencode:** retry failed schema probes ([974f41d](https://github.com/phall1/token-tach/commit/974f41d1f3cd878c873662f1133398138190f1f4))
* **predict:** advance burn rings on the wall clock, add per-agent burn ([c83c167](https://github.com/phall1/token-tach/commit/c83c16707b46e119ebaa7ea3e36c9e0a9f09ecee))
* **release:** harden automated publication ([e8776cb](https://github.com/phall1/token-tach/commit/e8776cbc901c0240a20975642e8257c4f8004247))
* **release:** pin recovery to version bump ([1c7a242](https://github.com/phall1/token-tach/commit/1c7a2424733a6065823e50f7fcc18f7eec17416b))
* **release:** read version portably on Linux ([1514a5e](https://github.com/phall1/token-tach/commit/1514a5efe4be97042830e1b2c84b13ab1b5efdd3))
* **release:** read version portably on Linux ([c709b88](https://github.com/phall1/token-tach/commit/c709b88d6f3866299f0a1935a67cc12704d0dff9))
* **ui:** close the last three honesty gaps and refresh the screenshots ([4875e0b](https://github.com/phall1/token-tach/commit/4875e0b13ddde41ff6ded530d9433fa20e5d9409))
* **ui:** unify the burn unit across all three surfaces ([94d9aae](https://github.com/phall1/token-tach/commit/94d9aaef7ffb39502030a86c3ede99ecd96f39db))


### Performance Improvements

* **collectors:** gate the expensive scans and stop re-parsing what is discarded ([5636ff0](https://github.com/phall1/token-tach/commit/5636ff08e809879d8235b19062263689a62f0788))
* **opencode:** skip unchanged database scans ([0b5d38c](https://github.com/phall1/token-tach/commit/0b5d38ce5ceff4f318b6282b8b599c9f1b5de055))
* reduce runtime memory and idle polling cost ([424c482](https://github.com/phall1/token-tach/commit/424c4827675f8b835d21d4a41e75de9c64580615))
* **runtime:** pool long-lived engine allocations ([f0e3640](https://github.com/phall1/token-tach/commit/f0e3640195f1be96e41893aa31ebc986052448ff))
* **system:** cache boot constants and CFStrings, split fast from slow samplers ([80b344c](https://github.com/phall1/token-tach/commit/80b344c0ce8f5188cfca91e44d715a66b1d49625))
