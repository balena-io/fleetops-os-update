
TARGET=v9.14.0

generate() {
    base=$1
    echo "Generating $base"
    rm -rf "${base}" || true
    mkdir -p "$base"
    (
        cd ${base} || return
        tar -xf ../${base}.tar
        calculated_sha=$(find -type f -name layer.tar | xargs sha256sum | sort | grep -v 5f70 | awk '{print $2}'|xargs cat | sha256sum | awk '{ print $1}')
        find -type f -name layer.tar | xargs sha256sum | sort | grep -v 5f70 | awk '{print $2}' | xargs cat > delta-base
        rdiff signature --block-size=128 delta-base delta-base.signature
        rdiff delta delta-base.signature ../${TARGET}.tar ../${base}-${TARGET}.delta
        xz -T 0 -9 -e -f ../${base}-${TARGET}.delta
        echo "${calculated_sha}  ${base}" >> ../../checksums.txt
    )
    rm -rf "$base"
}

echo "Clear checksum"
rm ../checksums.txt || true
versions=(v4.0.0 v4.0.0_logstream v4.1.1 v4.1.1_logstream v6.1.2 v6.1.2_logstream v6.2.1 v6.2.5 v6.2.5_logstream v6.6.11_logstream)
for v in ${versions[@]}; do
    generate $v
done
