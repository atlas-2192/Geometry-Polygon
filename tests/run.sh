#!/bin/bash

# ./run.sh [<test-name>]

set -e
cd $(dirname "${BASH_SOURCE[0]}")

OK=0
finish() { 
    rm -fr *.o
    rm -fr *.out
    rm -fr *.test
    rm -fr *.profraw
    rm -fr *.dSYM
    rm -fr *.profdata
    rm -fr *.out.wasm
    rm -fr *.out.js
    if [[ "$OK" != "1" ]]; then
        echo "FAIL"
    fi
}
trap finish EXIT

echo_wrapped() {
    # print an arguments list with line wrapping
    line=""
    for i in $(seq 1 "$#"); do
        line2="$line ${!i}"
        if [[ "${#line2}" -gt 70 ]]; then
            echo "$line \\"
            line="    "
        fi
        line="$line${!i} "
    done
    echo "$line"
}

if [[ -f /proc/cpuinfo ]]; then
    cpu="`cat /proc/cpuinfo | grep "model name" | uniq | cut -f3- -d ' ' | xargs`"
elif [[ "`which system_profiler`" != "" ]]; then
    cpu="`system_profiler SPHardwareDataType | grep Chip | uniq | cut -f2- -d ':' | xargs`"
fi
if [[ "$CC" == "" ]]; then
    CC=cc
fi
if [[ "$1" != "bench" ]]; then
    CFLAGS="-O0 -g3 -Wall -Wextra -fstrict-aliasing $CFLAGS"
    CCVERSHEAD="$($CC --version | head -n 1)"
    if [[ "$CCVERSHEAD" == "" ]]; then
        exit 1
    fi
    if [[ "$CCVERSHEAD" == *"clang"* ]]; then
        CLANGVERS="$(echo "$CCVERSHEAD" | awk '{print $4}' | awk -F'[ .]+' '{print $1}')"
    fi

    if [[ "$CC" == *"zig"* ]]; then
        # echo Zig does not support asans
        NOSANS=1
    fi

    # Use address sanitizer if possible
    if [[ "$NOSANS" != "1" && "$CLANGVERS" -gt "13" ]]; then
        CFLAGS="$CFLAGS -fno-omit-frame-pointer"
        CFLAGS="$CFLAGS -fprofile-instr-generate"
        CFLAGS="$CFLAGS -fcoverage-mapping"
        CFLAGS="$CFLAGS -fsanitize=address"
        CFLAGS="$CFLAGS -fsanitize=undefined"
        if [[ "$1" == "fuzz" ]]; then
            CFLAGS="$CFLAGS -fsanitize=fuzzer"
        fi
        CFLAGS="$CFLAGS -fno-inline"
        CFLAGS="$CFLAGS -pedantic"
        WITHSANS=1

        if [[ "$(which llvm-cov-$CLANGVERS)" != "" && "$(which llvm-profdata-$CLANGVERS)" != "" ]]; then
            LLVM_COV="llvm-cov-$CLANGVERS"
            LLVM_PROFDATA="llvm-profdata-$CLANGVERS"
        else
            LLVM_COV="llvm-cov"
            LLVM_PROFDATA="llvm-profdata"
        fi

        if [[ "$(which $LLVM_PROFDATA)" != "" && "$(which $LLVM_COV)" != "" ]]; then
            COV_VERS="$($LLVM_COV --version | awk '{print $4}' | awk -F'[ .]+' '{print $1}')"
            if [[ "$COV_VERS" -gt "15" ]]; then
                WITHCOV=1
            fi
        fi
    fi
    CFLAGS=${CFLAGS:-"-O0 -g3 -Wall -Wextra -fstrict-aliasing"}
else
    CFLAGS=${CFLAGS:-"-O3"}
fi
CC=${CC:-cc}
echo "CC: $CC"
echo "CFLAGS: $CFLAGS"
echo "OS: `uname`"
echo "CPU: $cpu"
cc2="$(readlink -f "`which $CC | true`" | true)"
if [[ "$cc2" == "" ]]; then
    cc2="$CC"
fi
echo Compiler: $($cc2 --version | head -n 1)
if [[ "$NOSANS" == "1" ]]; then
    echo "Sanitizers disabled"
fi
echo "TG Commit: `git rev-parse --short HEAD 2>&1 || true`"

# GEOS - used for benchmarking
if [[ "$GEOS_BENCH" == "1" ]]; then
    CFLAGS="$CFLAGS -DGEOS_BENCH"
    CFLAGS="$CFLAGS -Ilibgeos/build/install/include"
    GEOS_FLAGS="$GEOS_FLAGS bmalloc.cpp"
    GEOS_FLAGS="$GEOS_FLAGS libgeos/build/install/lib/libgeos_c.a"
    GEOS_FLAGS="$GEOS_FLAGS libgeos/build/install/lib/libgeos.a"
    GEOS_FLAGS="$GEOS_FLAGS -lm -pthread -lstdc++"
    ./geosbuild.sh
    GEOS_VERS="`libgeos/build/bin/geosop 2>&1 | head -n 1 | sed 's/.*GEOS //' || true`"
    GEOS_HASH="`cat libgeos/libgeos/GITHASH`"
    echo "GEOS: $GEOS_VERS-${GEOS_HASH:0:7}"
fi

if [[ "$1" == "bench" ]]; then
    echo "BENCHMARKING..."
    if [[ "$MARKDOWN" == "1" ]]; then
        echo_wrapped $CC $CFLAGS bmalloc.c ../tg.c bench.c -lm $GEOS_FLAGS
    else
        echo $CC $CFLAGS bmalloc.c ../tg.c bench.c -lm $GEOS_FLAGS
    fi
    $CC $CFLAGS bmalloc.c ../tg.c bench.c -lm $GEOS_FLAGS
    ./a.out $@
elif [[ "$1" == "fuzz" ]]; then
    echo "FUZZING..."
    echo $CC $CFLAGS ../tg.c fuzz.c
    $CC $CFLAGS ../tg.c fuzz.c
    MallocNanoZone=0 ./a.out corpus/ seeds/ # -jobs=8 # "${@:2}"
else
    if [[ "$WITHCOV" == "1" ]]; then
        echo "Code coverage: on"
    else 
        echo "Code coverage: off"
    fi
    echo "For benchmarks: 'run.sh bench'"
    echo "TESTING..."
    DEPS_SRCS="../deps/json.c ../deps/ryu.c"
    DEPS_OBJS="json.o ryu.o"
    rm -f tg.o $DEPS_OBJS
    for f in *; do 
        if [[ "$f" != test_*.c ]]; then continue; fi 
        if [[ "$1" == test_* ]]; then 
            p=$1
            if [[ "$1" == test_*_* ]]; then
                # fast track matching prefix with two underscores
                suf=${1:5}
                rest=${suf#*_}
                idx=$((${#suf}-${#rest}-${#_}+4))
                p=${1:0:idx}
            fi 
            if [[ "$f" != $p* ]]; then continue; fi
        fi
        if [[ ! -f "tg.o" ]]; then
            # Compile each dependency individually
            DEPS_SRCS_ARR=($DEPS_SRCS)
            for file in "${DEPS_SRCS_ARR[@]}"; do
                $CC $CFLAGS -Wunused-function -c $file
            done
            if [[ "$AMALGA" == "1" ]]; then
                echo "AMALGA=1"
                $CC $CFLAGS -c ../tg.c 
            else
                $CC $CFLAGS -DTG_NOAMALGA -c ../tg.c 
            fi
        fi
        if [[ "$AMALGA" == "1" ]]; then
            $CC $CFLAGS -o $f.test tg.o -lm $f
        else
            $CC $CFLAGS -DTG_NOAMALGA -o $f.test tg.o $DEPS_OBJS -lm $f
        fi
        if [[ "$WITHSANS" == "1" ]]; then
            export MallocNanoZone=0
        fi
        if [[ "$WITHCOV" == "1" ]]; then
            export LLVM_PROFILE_FILE="$f.profraw"
        fi
        if [[ "$VALGRIND" == "1" ]]; then
            valgrind --leak-check=yes ./$f.test $@
        else
            ./$f.test $@
        fi
    done
    OK=1
    echo "OK"

    if [[ "$COVREGIONS" == "" ]]; then 
        COVREGIONS="false"
    fi

    if [[ "$WITHCOV" == "1" ]]; then
        $LLVM_PROFDATA merge *.profraw -o test.profdata
        $LLVM_COV report *.test ../tg.c -ignore-filename-regex=.test. \
            -j=4 \
            -show-functions=true \
            -instr-profile=test.profdata > /tmp/test.cov.sum.txt
        # echo coverage: $(cat /tmp/test.cov.sum.txt | grep TOTAL | awk '{ print $NF }')
        echo covered: "$(cat /tmp/test.cov.sum.txt | grep TOTAL | awk '{ print $7; }') (lines)"
        $LLVM_COV show *.test ../tg.c -ignore-filename-regex=.test. \
            -j=4 \
            -show-regions=true \
            -show-expansions=$COVREGIONS \
            -show-line-counts-or-regions=true \
            -instr-profile=test.profdata -format=html > /tmp/test.cov.html
        echo "details: file:///tmp/test.cov.html"
        echo "summary: file:///tmp/test.cov.sum.txt"
    elif [[ "$WITHCOV" == "0" ]]; then
        echo "code coverage not a available"
        echo "install llvm-profdata and use clang for coverage"
    fi
fi
