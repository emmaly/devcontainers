#!/usr/bin/env bash

# Declare defaults
JRE_VERSION_DEFAULT="latest"
JRE_PACKAGE_DEFAULT="default-jre-headless"

# Test requested JRE package name against allowlist-pattern
allowed_jre_package_name() {
    package_name=${1:-$JRE_PACKAGE_DEFAULT}
    grep -E "^(default|openjdk)(-[0-9]+)?(-jre)(-headless)?$" <<<$package_name
}

# ENV
export DEBIAN_FRONTEND=noninteractive
JRE_VERSION=${VERSION:-$JRE_VERSION_DEFAULT}
JRE_PACKAGE_REQUESTED=$PACKAGE
JRE_PACKAGE=$(allowed_jre_package_name $JRE_PACKAGE_REQUESTED)

# Bail early
if [ "$JRE_VERSION" = "none" ]; then exit 0; fi
if [ "$JRE_PACKAGE_REQUESTED" = "none" ]; then exit 0; fi
if [ -z "$JRE_PACKAGE" ]; then
    echo "Invalid JRE package name pattern: $JRE_PACKAGE_REQUESTED"
    exit 1
fi



###

# Check execution permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Updates the apt package index if absent
apt_get_update() {
    if [ "$(find /var/lib/apt/lists/* 2>/dev/null | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update -yq || exit
    fi
}

# Clean up
apt_get_cleanup() {
    rm -rf /var/lib/apt/lists/* || exit
}

# Find a matching package version number
package_version() {
    local PACKAGE=$1
    local VERSION=$2

    if [ "$VERSION" = "latest" -o -z "$VERSION" ]; then
        echo "latest"
        # apt-cache madison $PACKAGE | head -n 1 | awk '{print $3}'
        return 0
    else
        pattern_exact="^([0-9]+:)?($VERSION)($)"
        pattern_prefix="^([0-9]+:)?($VERSION)(\.|\+|-)"

        # Check if the version matches to the end
        package_version_match=$(apt-cache madison $PACKAGE | awk '{print $3}' | grep -E $pattern_exact | head -n 1)

        if [ -z "$package_version_match" ]; then
            # Check if the version matches as a version prefix
            package_version_match=$(apt-cache madison $PACKAGE | awk '{print $3}' | grep -E $pattern_prefix | head -n 1)
        fi

        # If we found a match, return it
        if [ ! -z "$package_version_match" ]; then
            echo $package_version_match
            return 0
        fi
    fi

    echo "Unable to find package $PACKAGE with version $VERSION" >&2
    return 1
}

# Checks if packages are installed and installs them if not
check_packages() {
    for PACKAGE in $@; do
        NAME_VERSION=$(sed 's/=/ /g' <<<$PACKAGE)
        NAME=$(awk '{ print $1 }' <<<$NAME_VERSION)
        VERSION=$(awk '{ print $2 }' <<<$NAME_VERSION)
        VERSION=${VERSION:-*}
        echo "Checking $NAME ($VERSION)..."
        INSTALLED_VERSION=$(dpkg -s $NAME 2>/dev/null | grep '^Version:' | awk '{ print $2 }')
        if [ -z "$INSTALLED_VERSION" ]; then
            apt_get_update
            echo "Installing $NAME ($VERSION)..."
            [ "*" = "$VERSION" ] && VERSION=""
            [ ! -z "$VERSION" ] && VERSION="=$VERSION"
            echo apt-get -y install --no-install-recommends "$NAME$VERSION"
        else
            echo "Package $NAME ($INSTALLED_VERSION) is already installed."
            if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
                echo "... which doesn't match the requested version; sorry."
            fi
        fi
    done
}

# Check if all supplied commands exist
command_exists() {
    type $@ >/dev/null 2>&1
}

# Install package
install_package() {
    PACKAGE=$1
    VERSION=$2

    # Check our package version number for availability
    PACKAGE_VERSION="$(package_version $PACKAGE $VERSION || echo '(fail)')"

    if [ "(fail)" = "$PACKAGE_VERSION" ]; then
        # Didn't find a match
        echo "Skipping $PACKAGE installation..." >&2
        return 1
    elif [ "latest" = "$PACKAGE_VERSION" ]; then
        # Install the package, latest version
        check_packages "$PACKAGE"
    else
        # Install the package, specific version
        check_packages "$PACKAGE=$PACKAGE_VERSION"
    fi
}

###



# If java is missing, we'll try to install.
if ! command_exists java; then
    # Clean up
    apt_get_cleanup

    # Ensure we've updated our package cache
    apt_get_update

    # Install our package
    install_package $JRE_PACKAGE $JRE_VERSION
    EXITCODE=$?

    # Clean up
    apt_get_cleanup
fi

# Return Success/failure
exit $EXITCODE
