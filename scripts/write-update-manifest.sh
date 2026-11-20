#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    printf '请传入同一版本的一个或多个发布 ZIP。\n' >&2
    exit 2
fi

release_version=''
assets=''
separator=''
for archive do
    name=$(basename -- "$archive")
    version=$(printf '%s\n' "$name" | sed -nE 's/^Codex-Speed-([0-9]+\.[0-9]+\.[0-9]+)-(arm64|x86_64|universal)\.zip$/\1/p')
    if [ -z "$version" ] || [ ! -f "$archive" ] || [ ! -s "$archive" ]; then
        printf '发布包名称或内容无效：%s\n' "$archive" >&2
        exit 1
    fi
    if [ -n "$release_version" ] && [ "$release_version" != "$version" ]; then
        printf '请使用同一版本的发布包。\n' >&2
        exit 1
    fi
    release_version=$version

    size=$(stat -L -f '%z' "$archive")
    digest=$(shasum -a 256 -- "$archive" | awk '{print $1}')
    if [ "${#digest}" -ne 64 ]; then
        printf '无法计算发布包摘要：%s\n' "$archive" >&2
        exit 1
    fi
    asset=$(printf '{"name":"%s","size":%s,"digest":"sha256:%s"}' "$name" "$size" "$digest")
    assets="$assets$separator$asset"
    separator=','
done

printf '{"assets":[%s]}\n' "$assets"
