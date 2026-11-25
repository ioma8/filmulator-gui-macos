vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO mermerico/librtprocess
    REF 8d32ac79b27e7e4b3bfc01858582d6035a1c1e03
    SHA512 f3a6f9d980c864e75efe70b18706332968c1844a500f46ed6643eadc38fda9a22d999722c63b564032effb01000e74459f780df335aad0faa20803be64bb60a3
    HEAD_REF master
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DBUILD_SHARED_LIBS=OFF
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(PACKAGE_NAME rtprocess CONFIG_PATH lib/cmake/rtprocess)

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE.txt")
