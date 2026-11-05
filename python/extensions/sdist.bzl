# Copyright 2023 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Use sdist as dependency

:::{seealso}
For user documentation see the [PyPI dependencies section](pypi-dependencies).
:::
"""

#sdist_archive =

load("@rules_python//python:defs.bzl", "PyInfo")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

sdist_build = '''
load("@rules_python//python/extensions:sdist.bzl", "py_sdist_library")
#
#py_sdist_library(
#    name = "pkg",
#    srcs = glob(["**/*"]),
#    deps = [
#        # Runtime deps known from requirements_lock.txt
#        "@pypi_six//:pkg",
#    ],
#    visibility = ["//visibility:public"],
#)
#'''
#
#sdist = module_extension(
#)
#
#
#def _py_sdist_library_impl(ctx):
#    site_packages = ctx.actions.declare_directory(ctx.label.name + '_site_packages')
#    
#    ctx.actions.run()
#    return PyInfo()
#
#
#py_sdist_library = rule(
#    implementation = _py_sdist_library_impl
#)

# ==============================================================================
# 3. BUILD RULE (Runs in Analysis & Execution Phases)
# ==============================================================================
def _py_sdist_library_impl(ctx):
    site_packages = ctx.actions.declare_directory(ctx.label.name + "_site_packages")
    sdist_root = ctx.files.srcs[0].owner.workspace_root or "."

    py_runtime = ctx.toolchains["@rules_python//python:toolchain_type"].py3_runtime
    if py_runtime.interpreter:
        # Hermetic toolchain (e.g. with --//python:use_hermetic_python=True)
        python_bin = py_runtime.interpreter.path
        #is_hermetic = "1"
        #inputs = depset(ctx.files.srcs, transitive = [py_runtime.files])
        py_files = [py_runtime.files]
    else:
        # System toolchain (protobuf's default @local_toolchains)
        python_bin = py_runtime.interpreter_path
        #is_hermetic = "0"
        #inputs = depset(ctx.files.srcs)
        py_files = []

    cc_toolchain = find_cc_toolchain(ctx)
    cc_bin = cc_toolchain.compiler_executable

    build_dep_files = [
        dep[DefaultInfo].default_runfiles.files
        for dep in ctx.attr.build_deps
    ]
    build_dep_roots = ":".join([
        dep.label.workspace_root
        for dep in ctx.attr.build_deps
    ])

    inputs = depset(
        ctx.files.srcs,
        transitive = py_files + [cc_toolchain.all_files] + build_dep_files,
    )
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [site_packages],
        command = """
            set -euo pipefail
            EXECROOT="$(pwd)"
            case "$1" in
                /*) PYTHON_BIN="$1" ;;
                *)  PYTHON_BIN="$EXECROOT/$1" ;;
            esac
            case "$2" in
                /*) export CC="$2" ;;
                *)  export CC="$EXECROOT/$2" ;;
            esac
            export LDSHARED="$CC -shared"
            export CIBUILDWHEEL=1
            export PYTHONPATH="$5:${PYTHONPATH:-}"

            SDIST_ROOT="$3"
            OUT_DIR="$EXECROOT/$4"
            BUILD_DEP_ROOTS="$5"
            mkdir -p "$OUT_DIR"
            TMP_BUILD="$(mktemp -d)"

            cd "$SDIST_ROOT"
            echo "@@@@ PySdistBuild.sh"
            echo "       \\$@: $@"
            echo "       PYTHON_BIN: $PYTHON_BIN"
            echo "       OUT_DIR: $OUT_DIR"
            echo "       TMP_BUILD: $TMP_BUILD"
            echo "       EXECROOT: $EXECROOT"
            echo "       BUILD_DEP_ROOTS: $BUILD_DEP_ROOTS"
            "$PYTHON_BIN" - "$OUT_DIR" "$TMP_BUILD" "$EXECROOT" "$BUILD_DEP_ROOTS" << 'EOF'
import os
import sys

out_dir = sys.argv[1]
tmp_build = sys.argv[2]
execroot = sys.argv[3]
build_dep_roots = sys.argv[4]

# Put build_deps (like @pypi__setuptools//:lib) at the very front of sys.path
for rel_root in reversed(build_dep_roots.split(":")):
    if rel_root:
        sys.path.insert(0, os.path.join(execroot, rel_root))
sys.path.insert(0, os.getcwd())

import setuptools
print("Using setuptools from:", setuptools.__file__)

sys.argv = [
    "setup.py",
    "build",
    "--build-base", tmp_build,
    "--build-lib", out_dir,
]
print('$$$$ PySdistBuild.sh.py')
print('       out_dir: {}'.format(out_dir))
print('       tmp_build: {}'.format(tmp_build))
print('       sys.path: {}'.format(sys.path))
print('       sys.argv: {}'.format(sys.argv))
if os.path.exists("setup.py"):
    print('       using setup.py')
    with open("setup.py", "rb") as f:
        code = compile(f.read(), "setup.py", "exec")
    exec(code, {"__name__": "__main__", "__file__": "setup.py"})
else:
    print('       using setuptools.setup()')
    setuptools.setup()
EOF
        """,
        arguments = [python_bin, cc_bin, sdist_root, site_packages.path, build_dep_roots],
        mnemonic = "PySdistBuild",
        progress_message = "Building Python sdist %{label}",
    )

    if site_packages.short_path.startswith("../"):
        import_path = site_packages.short_path.removeprefix("../")
    else:
        import_path = "{}/{}".format(ctx.workspace_name, site_packages.short_path)

    runfiles = ctx.runfiles(files = [site_packages]).merge_all([
        dep[DefaultInfo].default_runfiles
        for dep in ctx.attr.deps
    ])

    print(':::: _py_sdist_library_impl')
    print('   1    ctx: {}'.format(dir(ctx)))
    print('   1    ctx.label: {}'.format(dir(ctx.label)))
    print('   1    ctx.label.name: {}'.format(ctx.label.name))
    print('   1    ctx.label.package: {}'.format(ctx.label.package))
    print('   1    ctx.label.relative: {}'.format(ctx.label.relative))
    print('   1    ctx.label.repo_name: {}'.format(ctx.label.repo_name))
    print('   1    ctx.label.repo_root: {}'.format(ctx.label.repo_root))
    print('   1    ctx.label.same_package_label: {}'.format(ctx.label.same_package_label))
    print('   1    ctx.label.workspace_name: {}'.format(ctx.label.workspace_name))
    print('   1    ctx.label.workspace_root: {}'.format(ctx.label.workspace_root))
    print('   1    ctx.package_relative_label: {}'.format(ctx.package_relative_label))
    #print('   1    ctx.rule: {}'.format(dir(ctx.rule)))
    print('   1    ctx.attr: {}'.format(dir(ctx.attr)))
    print('   2    ctx.attr.name: {}'.format(ctx.attr.name))
    print('   3    ctx.attr.deps: {}'.format(ctx.attr.deps))

    print('   4    ctx.attr._cc_toolchain: {}'.format(ctx.attr._cc_toolchain))
    print('   5    ctx.attr._config_dependencies: {}'.format(ctx.attr._config_dependencies))
    print('   6    ctx.attr.build_deps: {}'.format(ctx.attr.build_deps))
    print('   7    ctx.attr.compatible_with: {}'.format(ctx.attr.compatible_with))
    print('   8    ctx.attr.deprecation: {}'.format(ctx.attr.deprecation))
    print('   9    ctx.attr.exec_compatible_with: {}'.format(ctx.attr.exec_compatible_with))
    print('  10    ctx.attr.exec_properties: {}'.format(ctx.attr.exec_properties))
    print('  11    ctx.attr.expect_failure: {}'.format(ctx.attr.expect_failure))
    print('  12    ctx.attr.features: {}'.format(ctx.attr.features))
    print('  13    ctx.attr.generator_function: {}'.format(ctx.attr.generator_function))
    print('  14    ctx.attr.generator_location: {}'.format(ctx.attr.generator_location))
    print('  15    ctx.attr.generator_name: {}'.format(ctx.attr.generator_name))
    print('  16    ctx.attr.package_metadata: {}'.format(ctx.attr.package_metadata))
    print('  17    ctx.attr.restricted_to: {}'.format(ctx.attr.restricted_to))
    print('  18    ctx.attr.srcs: {}'.format(ctx.attr.srcs))
    print('  19    ctx.attr.tags: {}'.format(ctx.attr.tags))
    print('  20    ctx.attr.target_compatible_with: {}'.format(ctx.attr.target_compatible_with))
    print('  21    ctx.attr.testonly: {}'.format(ctx.attr.testonly))
    print('  22    ctx.attr.toolchains: {}'.format(ctx.attr.toolchains))
    print('  23    ctx.attr.transitive_configs: {}'.format(ctx.attr.transitive_configs))
    print('  24    ctx.attr.visibility: {}'.format(ctx.attr.visibility))

    print('  25    python_bin: {}'.format(python_bin))
    print('  26    py_runtime.interpreter: {}'.format(py_runtime.interpreter))
    print('  27    cc_bin: {}'.format(cc_bin))
    print('  28    sdist_root: {}'.format(sdist_root))
    print('  29    site_packages.path: {}'.format(site_packages.path))
    #print('  30    build_pythonpath: {}'.format(build_pythonpath))
    print('  31    runfiles: {}'.format(runfiles))
    print('  32    import_path: {}'.format(import_path))

    return [
        DefaultInfo(
            files = depset([site_packages]),
            runfiles = runfiles,
        ),
        PyInfo(
            transitive_sources = depset(
                [site_packages],
                transitive = [dep[PyInfo].transitive_sources for dep in ctx.attr.deps],
            ),
            imports = depset(
                [import_path],
                transitive = [dep[PyInfo].imports for dep in ctx.attr.deps],
            ),
        ),
    ]

py_sdist_library = rule(
    implementation = _py_sdist_library_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "deps": attr.label_list(providers = [PyInfo]),
        "build_deps": attr.label_list(
            default = ["@pypi__setuptools//:lib"],
            providers = [PyInfo],
        ),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
    toolchains = [
        "@rules_python//python:toolchain_type"
    ] + use_cc_toolchain(),
)
# ==============================================================================
# 2. REPOSITORY RULE (Runs in Fetch Phase)
# ==============================================================================
def _sdist_repo_impl(rctx):
    # 1. Download and extract the sdist tarball into this external repo's root.
    rctx.download_and_extract(
        url = rctx.attr.url,
        sha256 = rctx.attr.sha256,
        strip_prefix = rctx.attr.strip_prefix,
    )
    # 2. Write a BUILD.bazel file that hands the extracted files to our build rule.
    rctx.file("BUILD.bazel", """
load("@rules_python//python/extensions:sdist.bzl", "py_sdist_library")
py_sdist_library(
    name = "pkg",
    srcs = glob(["**/*"], exclude = ["BUILD.bazel", "WORKSPACE"]),
    deps = {deps},
    visibility = ["//visibility:public"],
)
""".format(deps = repr(rctx.attr.deps)))
sdist_repo = repository_rule(
    implementation = _sdist_repo_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "deps": attr.string_list(),
    },
)
# ==============================================================================
# 1. MODULE EXTENSION (Bridges MODULE.bazel -> sdist_repo)
# ==============================================================================
def _sdist_ext_impl(mctx):
    for mod in mctx.modules:
        for archive in mod.tags.archive:
            sdist_repo(
                name = archive.name,
                url = archive.url,
                sha256 = archive.sha256,
                strip_prefix = archive.strip_prefix,
                deps = archive.deps,
            )
_archive_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "deps": attr.string_list(),
    },
)
sdist = module_extension(
    implementation = _sdist_ext_impl,
    tag_classes = {"archive": _archive_tag},
)
