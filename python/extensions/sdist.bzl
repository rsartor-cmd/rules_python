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
        is_hermetic = "1"
        inputs = depset(ctx.files.srcs, transitive = [py_runtime.files])
    else:
        # System toolchain (protobuf's default @local_toolchains)
        python_bin = py_runtime.interpreter_path
        is_hermetic = "0"
        inputs = depset(ctx.files.srcs)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [site_packages],
        command = """
            set -euo pipefail
            if [ "$2" = "1" ]; then
                PYTHON_BIN="$(pwd)/$1"
            else
                PYTHON_BIN="$1"
            fi
            SDIST_ROOT="$3"
            OUT_DIR="$(pwd)/$4"
            mkdir -p "$OUT_DIR"

            cd "$SDIST_ROOT"
            "$PYTHON_BIN" - "$OUT_DIR" << 'EOF'
import os
import shutil
import sys

out_dir = sys.argv[1]
sys.path.insert(0, os.getcwd())

# 1. Inspect pyproject.toml if present
backend_name = "setuptools.build_meta"
if os.path.exists("pyproject.toml"):
    import tomllib
    with open("pyproject.toml", "rb") as f:
        pyproject = tomllib.load(f)
    backend_name = pyproject.get("build-system", {}).get(
        "build-backend", "setuptools.build_meta"
    )

# 2. Try setuptools if available in this Python environment
import setuptools
if backend_name.startswith("setuptools") and hasattr(setuptools, "setup"):
    sys.argv = ["setup.py", "build", "--build-lib", out_dir]
    if os.path.exists("setup.py"):
        with open("setup.py", "rb") as f:
            code = compile(f.read(), "setup.py", "exec")
        exec(code, {"__name__": "__main__", "__file__": "setup.py"})
    else:
        setuptools.setup()
else:
    # 3. Fallback when running on system Python without setuptools installed:
    #    stage pure-Python packages from `src/` or the sdist root into `out_dir`.
    search_root = "src" if os.path.isdir("src") else "."
    for entry in os.listdir(search_root):
        full_path = os.path.join(search_root, entry)
        if os.path.isdir(full_path) and os.path.isfile(os.path.join(full_path, "__init__.py")):
            shutil.copytree(full_path, os.path.join(out_dir, entry), dirs_exist_ok=True)
EOF
        """,
        arguments = [python_bin, is_hermetic, sdist_root, site_packages.path],
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
    },
    toolchains = ["@rules_python//python:toolchain_type"],
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
