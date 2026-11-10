PY := .venv/bin/python
.PHONY: setup bootstrap rewrite verify shaders mac app run test
setup:
	python3 -m venv .venv
	$(PY) -m pip install -r requirements.txt
bootstrap:
	$(PY) tools/dr3.py bootstrap
rewrite:
	$(PY) tools/dr3.py rewrite
verify:
	$(PY) tools/dr3.py verify
shaders:
	$(PY) tools/dr3.py shaders
mac:
	$(PY) tools/dr3.py build
app: mac
	$(PY) tools/mac_app.py
run:
	$(PY) tools/dr3.py run --seconds 30
test:
	$(PY) -m unittest discover -s tests -v
	clang -O1 -Wall -Wno-unused-function -Ithird_party/nxnative/dm/host/gen/01001B300B9BE000 -o work/test-account tests/test_account.c
	./work/test-account

	clang -O1 -Wall -fobjc-arc tests/test_ios_assets.m -framework Foundation -o work/test-ios-assets
	./work/test-ios-assets

	clang -O1 -Wall -Ithird_party/nxnative/dm/gfx/nvn/include tests/test_program_snapshot.c -o work/test-program-snapshot
	./work/test-program-snapshot

	clang -O1 -g -Wall -Wno-unused-function -Wno-unused-variable -fobjc-arc -Ithird_party/nxnative/dm/host -Ithird_party/nxnative/dm/host/gen/01001B300B9BE000 tests/test_gamepad.m -framework Foundation -framework GameController -o work/test-gamepad
	./work/test-gamepad

	clang -O1 -Wall -Wno-unused-function -Inative -Ithird_party/nxnative/dm/host/gen/01001B300B9BE000 tests/test_controller_effects.c -o work/test-controller-effects
	./work/test-controller-effects

	clang -std=c11 -O1 -Wall -Wextra -Werror tests/test_sixaxis_math.c -lm -o work/test-sixaxis-math
	./work/test-sixaxis-math

	clang -std=c11 -O1 -Wall -Wextra -Werror -Iplatform/ios/Sources tests/test_touch_layout.c platform/ios/Sources/DmTouchLayout.c -lm -o work/test-touch-layout
	./work/test-touch-layout

	clang -O1 -Wall -fobjc-arc tests/test_controller_effects_probe.m native/controller_effects.m -framework Foundation -framework GameController -framework CoreHaptics -o work/test-controller-effects-probe
	./work/test-controller-effects-probe

	clang -O1 -Wall -fobjc-arc tests/test_uniform_forward.m -framework Metal -framework Foundation -o work/test-uniform-forward
	./work/test-uniform-forward

	clang -O1 -Wall -fobjc-arc tests/test_uniform_dependencies.m -framework Metal -framework Foundation -o work/test-uniform-dependencies
	./work/test-uniform-dependencies

	clang -O1 -Wall -fobjc-arc tests/test_vertex_fetch.m -framework Metal -framework Foundation -o work/test-vertex-fetch
	./work/test-vertex-fetch work/build/cache/metal_shader_cache/b-87c50a868147

	clang -O1 -Wall -fobjc-arc tests/test_metalfx_spatial.m -framework Metal -framework MetalFX -framework Foundation -o work/test-metalfx-spatial
	./work/test-metalfx-spatial

	$(PY) tests/run_nvn_commands.py
	$(PY) tests/run_upstream_nvn.py
