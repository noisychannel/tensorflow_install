#!/usr/bin/env bash

# Built for the CLSP@JHU cluster.
# Installs Tensorflow and Bazel from source
# Author : Gaurav Kumar

set -e

shopt -s expand_aliases
source ~/.bashrc

# GCC 4.9 : You may choose to change these if you have your own install
GCC_ROOT=/home/gkumar/.local
GCC_BIN=$GCC_ROOT/bin
GCC_LIB=$GCC_ROOT/lib/gcc
GCC_LIB64=$GCC_ROOT/lib64
GCC_INCLUDE=$GCC_ROOT/include

# NVIDIA headers
NVIDIA_HEADERS=/opt/NVIDIA/cuda-7.0/include

# Python user-site
PY_USER_SITE=/home/gkumar/.local/lib/python2.7/site-packages

export JNI_LD_ARGS="-L$GCC_LIB64 -Wl,-rpath,$GCC_LIB64 -B$GCC_BIN"

function fix_bazel() {
  # Bug : https://github.com/bazelbuild/bazel/issues/591
  # Tensorflow requires > GCC 4.8 and CLSP has 4.7
  # Bazel refuses to build with anything other than /usr/bin/gcc
  # Inspired by @sethbruder
  for file in tools/cpp/CROSSTOOL src/test/java/com/google/devtools/build/lib/MOCK_CROSSTOOL; do
    for e in $( ls $GCC_BIN ); do
      sed -i 's:/usr/bin/'$e':'$GCC_BIN'/'$e':g' $file
    done

    # For the linker_flag
    sed -i 's:linker_flag\: "-B/usr/bin/":linker_flag\: "-B'$GCC_BIN'/"\n  linker_flag\: "-L'$GCC_LIB64'"\n  linker_flag\: "-Wl,-rpath,'$GCC_LIB64'":g' $file
    # cxx_builtin_include_directory
    sed -i 's:/usr/lib/gcc/:'$GCC_LIB'/:g' $file
    sed -i 's:/usr/local/include:'$GCC_INCLUDE':g' $file
  done
}

function fix_tf() {
  # Cross-tool requires updates similar to the Bazel crosstool
  # Fix a few other hardcoded details
  sed -i 's:/usr/bin/gcc:'$GCC_BIN'/gcc:g' third_party/gpus/crosstool/clang/bin/crosstool_wrapper_driver_is_not_gcc

  for file in third_party/gpus/crosstool/CROSSTOOL; do
    for e in $( ls $GCC_BIN ); do
      sed -i 's:/usr/bin/'$e':'$GCC_BIN'/'$e':g' $file
    done

    # For the linker_flag
    sed -i 's:linker_flag\: "-B/usr/bin/":linker_flag\: "-B'$GCC_BIN'/"\n  linker_flag\: "-L'$GCC_LIB64'"\n  linker_flag\: "-Wl,-rpath,'$GCC_LIB64'":g' $file
    # cxx_builtin_include_directory
    sed -i 's:cxx_builtin_include_directory\: "/usr/lib/gcc/":cxx_builtin_include_directory\: "'$GCC_LIB'"\n  cxx_builtin_include_directory\: "'$NVIDIA_HEADERS'":g' $file
    sed -i 's:/usr/local/include:'$GCC_INCLUDE':g' $file
  done

  sed -i 's:return \[\]  # No extension link opts:return \["-lrt"\]:g' tensorflow/tensorflow.bzl
  # Add cuda.h as dependency to stream_executor
  sed -i 's:"platform/\*\*/\*\.h",:"platform/\*\*/\*\.h",\n        "cuda/\*\.h",:' tensorflow/stream_executor/BUILD
  # Headers in framework and util should be available to core
  sed -i 's:name = "gpu_kernels",:name = "gpu_kernels",\n    hdrs = glob(\["framework/\*\.h","util/\*\.h"\]),:g' tensorflow/core/BUILD
}

if [ $(javac -version 2>&1 | awk -F'.' '{print $2}') -ne 8 ];
then
  echo >&2 "Upgrade JDK to 1.8 and try again. Don't forget to set JAVA_HOME";
  exit 1;
fi

# Install Bazel
command -v bazel >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "*** Bazel is not installed. Installing from scratch."
  git clone https://github.com/bazelbuild/bazel.git
  cd bazel
  fix_bazel
  echo 'build --verbose_failures' > bazelrc
  export BAZELRC=`pwd`/bazelrc
  ./compile.sh
  cd ..
  export PATH=$PATH:`pwd`/bazel/output
else
  bazel_location=`command -v bazel 2>&1`
  echo "*** Bazel is installed at ${bazel_location}. Using that."
fi

INCLUDE_PY=$(python -c "from distutils import sysconfig as s; print s.get_config_vars()['INCLUDEPY']")
if [ ! -f "${INCLUDE_PY}/Python.h" ]; then
  echo "ERROR: python-devel not installed" >&2
  exit 1
else
  echo "*** Found python-dev"
fi

python -c "import numpy" || { echo "Python-numpy not installed"; exit 1; }
if [ $(python -c "import numpy; print numpy.version.version" | awk -F'.' '{print $2}') -gt 8 ]; then
  echo "*** Found Numpy version >= 0.9";
else
  echo "FATAL : Numpy version < 0.9. Upgrade numpy and restart";
fi

command -v swig >/dev/null 2>&1 || { echo "Swig not installed"; exit 1; }
echo "*** Found SWIG"

echo "*** Installing Tensorflow"
git clone --recurse-submodules https://github.com/tensorflow/tensorflow

if [ -d /usr/local/cuda ]; then
  echo "*** Found CUDA. Make sure CuDNN is installed and provide the location
  to the installer."
else
  echo "*** Did not find CUDA. Installing tensorflow without GPU support"
fi

cd tensorflow
fix_tf
./configure
# With GPU support
#bazel build -c opt --config=cuda //tensorflow/tools/pip_package:build_pip_package --verbose_failures
# Without GPU support
bazel build -c opt //tensorflow/tools/pip_package:build_pip_package --verbose_failures
bazel-bin/tensorflow/tools/pip_package/build_pip_package `pwd`/tensorflow_pkg
# Remove existing tensorflow pip package if it exists
if [ -d $PY_USER_SITE/tensorflow ]; then
  rm -rf $PY_USER_SITE/tensorflow*
fi
pip install --user tensorflow_pkg/tensorflow-0.6.0-py2-none-any.whl
cd ..
