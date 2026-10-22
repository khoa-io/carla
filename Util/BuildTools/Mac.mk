PYTHON ?= python3
MACOS_ARGS ?=
MACOSX_DEPLOYMENT_TARGET ?= 12.0
MACOS_SMOKE_PORT ?= 42916
MACOS_ENGINE_ROOT ?= $(CARLA_BUILD_FOLDER)/macos-engine/source
export MACOSX_DEPLOYMENT_TARGET

.PHONY: default help setup LibCarla LibCarla.client LibCarla.client.release PythonAPI PythonAPI.wheel check.LibCarla check.PythonAPI launch launch-only CarlaUE4Editor package
.PHONY: LibCarla.server check.LibCarla.server check.PhysX
.PHONY: check.Metal
.PHONY: setup.assets
.PHONY: CarlaUE4Editor CarlaUE4 check.Simulator

default: help

help:
	@echo 'Native Apple Silicon build of CARLA 0.9.16:'
	@echo '  make LibCarla.client PYTHON=/absolute/path/to/python3.11'
	@echo '  make PythonAPI.wheel PYTHON=/absolute/path/to/python3.11'
	@echo '  make check.LibCarla PYTHON=/absolute/path/to/python3.11'
	@echo '  make check.PythonAPI PYTHON=/absolute/path/to/python3.11'
	@echo '  make LibCarla.server (requires native client dependencies)'
	@echo '  make check.LibCarla.server; make check.PhysX'
	@echo '  make check.Metal (native GPU compile/dispatch/readback)'
	@echo '  make setup.assets (verified 0.9.16 source content; large download)'
	@echo '  make CarlaUE4Editor (native ARM64 CARLA editor and engine target)'
	@echo '  make CarlaUE4 (native ARM64 standalone CARLA game target)'
	@echo '  make check.Simulator (native server, vehicle and RGB frame acceptance test)'
	@echo '  MACOS_ARGS="--jobs 4" controls dependency/client compilation.'
	@echo '  The simulator targets need the native Python environment, for example'
	@echo '  make check.Simulator PYTHON="$(CURDIR)/Build/macos/wheel-test/bin/python"'
	@echo '  See Docs/build_macos.md for the prerequisites and the known limitations.'

setup:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacBuildClient.sh" --python "$(PYTHON)" --dependencies-only $(MACOS_ARGS)

setup.assets:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacInstallAssets.sh"

LibCarla LibCarla.client: LibCarla.client.release

LibCarla.client.release:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacBuildClient.sh" --python "$(PYTHON)" $(MACOS_ARGS)

PythonAPI: PythonAPI.wheel

LibCarla.server:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacBuildServer.sh" $(MACOS_ARGS)

check.LibCarla.server: LibCarla.server
	@xcrun clang++ -std=c++14 -stdlib=libc++ -arch arm64 -mmacosx-version-min="$(MACOSX_DEPLOYMENT_TARGET)" -DBOOST_ERROR_CODE_HEADER_ONLY -DLIBCARLA_NO_EXCEPTIONS -DBOOST_NO_EXCEPTIONS -DASIO_NO_EXCEPTIONS -isystem "${CARLA_ROOT_FOLDER}/Unreal/CarlaUE4/Plugins/Carla/CarlaDependencies/include" "${CARLA_BUILD_TOOLS_FOLDER}/Tests/MacServerSmoke.cpp" -L"${CARLA_ROOT_FOLDER}/Unreal/CarlaUE4/Plugins/Carla/CarlaDependencies/lib" -lcarla_server -losm2odr -lxerces-c -lproj -lsqlite3 -lz -liconv -o "${CARLA_BUILD_FOLDER}/macos-server-arm64/server-smoke"
	@PROJ_LIB="${CARLA_ROOT_FOLDER}/Unreal/CarlaUE4/Plugins/Carla/CarlaDependencies/share/proj" "${CARLA_BUILD_FOLDER}/macos-server-arm64/server-smoke"

check.PhysX:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacBuildPhysX.sh" --engine "$(MACOS_ENGINE_ROOT)"

check.Metal:
	@mkdir -p "${CARLA_BUILD_FOLDER}/macos-metal"
	@xcrun -sdk macosx metal -std=macos-metal2.3 -mmacosx-version-min="$(MACOSX_DEPLOYMENT_TARGET)" -c "${CARLA_BUILD_TOOLS_FOLDER}/Tests/MacMetalSmoke.metal" -o "${CARLA_BUILD_FOLDER}/macos-metal/smoke.air"
	@xcrun -sdk macosx metallib "${CARLA_BUILD_FOLDER}/macos-metal/smoke.air" -o "${CARLA_BUILD_FOLDER}/macos-metal/smoke.metallib"
	@xcrun clang++ -std=c++14 -arch arm64 -mmacosx-version-min="$(MACOSX_DEPLOYMENT_TARGET)" -fobjc-arc -framework Foundation -framework Metal "${CARLA_BUILD_TOOLS_FOLDER}/Tests/MacMetalSmoke.mm" -o "${CARLA_BUILD_FOLDER}/macos-metal/metal-smoke"
	@"${CARLA_BUILD_FOLDER}/macos-metal/metal-smoke" "${CARLA_BUILD_FOLDER}/macos-metal/smoke.metallib"

PythonAPI.wheel: LibCarla.client.release
	@cd "${CARLA_PYTHONAPI_SOURCE_FOLDER}" && "$(PYTHON)" -m build --wheel --no-isolation

check.LibCarla: LibCarla.client.release
	@xcrun clang++ -std=c++14 -stdlib=libc++ -arch arm64 -mmacosx-version-min="$(MACOSX_DEPLOYMENT_TARGET)" -DBOOST_ERROR_CODE_HEADER_ONLY -I"${LIBCARLA_INSTALL_CLIENT_FOLDER}/include" -isystem "${LIBCARLA_INSTALL_CLIENT_FOLDER}/include/system" "${CARLA_BUILD_TOOLS_FOLDER}/Tests/MacClientSmoke.cpp" -L"${LIBCARLA_INSTALL_CLIENT_FOLDER}/lib" -lcarla_client -lrpc -lboost_filesystem -lRecast -lDetour -lDetourCrowd -lpng -lz -o "${CARLA_BUILD_FOLDER}/macos-arm64/client-smoke"
	@"${CARLA_BUILD_FOLDER}/macos-arm64/client-smoke" "$(MACOS_SMOKE_PORT)"

check.PythonAPI:
	@"$(PYTHON)" -c 'import carla, platform; from importlib.metadata import version; assert platform.machine() == "arm64"; assert version("carla") == "0.9.16"; assert carla.Client("127.0.0.1", 2000).get_client_version() == "0.9.16"; print("Testing installed native extension:", carla.libcarla.__file__)'
	@"$(PYTHON)" -m unittest discover -s "${CARLA_PYTHONAPI_ROOT_FOLDER}/test/unit" -p 'test_transform.py'
	@"$(PYTHON)" -m unittest discover -s "${CARLA_PYTHONAPI_ROOT_FOLDER}/test/unit" -p 'test_vehicle.py'

CarlaUE4Editor:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacBuildEditor.sh" --engine-root "$(MACOS_ENGINE_ROOT)" --jobs 6

CarlaUE4:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacBuildGame.sh" --engine-root "$(MACOS_ENGINE_ROOT)" --jobs 6

check.Simulator:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacRunSimulator.sh" --engine-root "$(MACOS_ENGINE_ROOT)" --python "$(PYTHON)"

launch: CarlaUE4Editor
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacRunSimulator.sh" --engine-root "$(MACOS_ENGINE_ROOT)" --python "$(PYTHON)" --keep-running

launch-only:
	@bash "${CARLA_BUILD_TOOLS_FOLDER}/MacRunSimulator.sh" --engine-root "$(MACOS_ENGINE_ROOT)" --python "$(PYTHON)" --keep-running

package:
	@echo 'A native ARM64 packaged distribution needs the content to be cooked for macOS, which is not done yet. See Docs/build_macos.md.' >&2
	@exit 2
