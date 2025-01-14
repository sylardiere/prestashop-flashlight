#!/bin/bash
set -e
cd "$(dirname "$0")"

# Available variables
# -------------------
declare PS_VERSION;      # -- PrestaShop version, defaults to latest
declare PHP_VERSION;     # -- PHP version, defaults to recommended version for PrestaShop
declare OS_FLAVOUR;      # -- either "alpine" (default) or "debian"
declare SERVER_FLAVOUR;  # -- not implemented, either "nginx" (default) or "apache"
declare TARGET_PLATFORM;  # -- a comma separated list of target platforms (defaults to "linux/amd64")
declare PLATFORM;        # -- alias for $TARGET_PLATFORM
declare TARGET_IMAGE;    # -- docker image name, defaults to "prestashop/prestashop-flashlight"
declare PUSH;            # -- set it to "true" if you want to push the resulting image

# Static configuration
# --------------------
DEFAULT_OS="alpine";
DEFAULT_SERVER="nginx";
DEFAULT_DOCKER_IMAGE=prestashop/prestashop-flashlight
DEFAULT_PLATFORM=$(docker system info --format '{{.OSType}}/{{.Architecture}}')
GIT_SHA=$(git rev-parse HEAD)
TARGET_PLATFORM="${TARGET_PLATFORM:-${PLATFORM:-$DEFAULT_PLATFORM}}"

error() {
  echo -e "\e[1;31m${1:-Unknown error}\e[0m"
  exit "${2:-1}"
}

get_latest_prestashop_version() {
  curl --silent --show-error --fail --location --request GET \
    'https://api.github.com/repos/prestashop/prestashop/releases/latest' | jq -r '.tag_name'
}

get_recommended_php_version() {
  local PS_VERSION=$1;
  local RECOMMENDED_VERSION=;
  REGEXP_LIST=$(jq -r 'keys_unsorted | .[]' <prestashop-versions.json)
  while IFS= read -r regExp; do
    if [[ $PS_VERSION =~ $regExp ]]; then
      RECOMMENDED_VERSION=$(jq -r '."'"${regExp}"'".php.recommended' <prestashop-versions.json)
      break;
    fi
  done <<<"$REGEXP_LIST"
  echo "$RECOMMENDED_VERSION";
}

get_recommended_nodejs_version() {
  local PS_VERSION=$1;
  local RECOMMENDED_VERSION=;
  REGEXP_LIST=$(jq -r 'keys_unsorted | .[]' <prestashop-versions.json)
  while IFS= read -r regExp; do
    if [[ $PS_VERSION =~ $regExp ]]; then
      RECOMMENDED_VERSION=$(jq -r '."'"${regExp}"'".nodejs.recommended' <prestashop-versions.json)
      break;
    fi
  done <<<"$REGEXP_LIST"
  echo "$RECOMMENDED_VERSION";
}

get_php_flavour() {
   local OS_FLAVOUR=${1:-};
   local SERVER_FLAVOUR=${2:-};
   local PHP_VERSION=${3:-};
   jq -r '."'"${PHP_VERSION}"'".'"${OS_FLAVOUR}" <php-flavours.json;
}

get_ps_version() {
  local PS_VERSION=${1:-};
  if [ -z "$PS_VERSION" ] || [ "$PS_VERSION" == "latest" ] ; then
    get_latest_prestashop_version;
  else
    echo "$PS_VERSION";
  fi
}

get_php_version() {
  local PHP_VERSION=${1:-};
  local PS_VERSION=${2:-};
  if [ -z "$PHP_VERSION" ] || [ "$PHP_VERSION" == "latest" ] ; then
    get_recommended_php_version "$PS_VERSION"
  else
    echo "$PHP_VERSION";
  fi
}

#
# if the build is for the latest image of the default OS with the recommended PHP version, these tags will be like:
# * latest
# * php-8.2
# * 8.1.1
# * 8.1.1-8.2
# * 8.1.1-8.2-alpine
#
get_target_images() {
  local PHP_FLAVOUR=${1:-};
  local PS_VERSION=${2:-};
  local PHP_VERSION=${3:-};
  local OS_FLAVOUR=${4:-};
  declare RES;
  if [ "$PS_VERSION" = "$(get_latest_prestashop_version)" ] && [ "$OS_FLAVOUR" = "$DEFAULT_OS" ]; then
    RES="-t ${DEFAULT_DOCKER_IMAGE}:latest";
  fi
  if [ "$OS_FLAVOUR" = "$DEFAULT_OS" ]; then
    RES="${RES} -t ${DEFAULT_DOCKER_IMAGE}:${PS_VERSION}-${PHP_VERSION}";
    if [ "$PHP_VERSION" = "$(get_recommended_php_version "$PS_VERSION")" ]; then
      RES="${RES} -t ${DEFAULT_DOCKER_IMAGE}:${PS_VERSION}";
      RES="${RES} -t ${DEFAULT_DOCKER_IMAGE}:php-${PHP_VERSION}";
    fi
  fi
  RES="${RES} -t ${DEFAULT_DOCKER_IMAGE}:${PS_VERSION}-${PHP_FLAVOUR}";
  RES="${RES} -t ${DEFAULT_DOCKER_IMAGE}:${PS_VERSION}-${OS_FLAVOUR}";
  echo "$RES";
}

# Applying configuration
# ----------------------
PS_VERSION=$(get_ps_version "$PS_VERSION");
PHP_VERSION=$(get_php_version "$PHP_VERSION" "$PS_VERSION");
if [ -z "$PHP_VERSION" ]; then
  error "Could not find a recommended PHP version for PS_VERSION: $PS_VERSION" 2
fi
OS_FLAVOUR=${OS_FLAVOUR:-$DEFAULT_OS};
SERVER_FLAVOUR=${SERVER_FLAVOUR:-$DEFAULT_SERVER};
PHP_FLAVOUR=$(get_php_flavour "$OS_FLAVOUR" "$SERVER_FLAVOUR" "$PHP_VERSION");
NODE_VERSION=$(get_recommended_nodejs_version "$PS_VERSION");
if [ "$PHP_FLAVOUR" == "null" ]; then
  error "Could not find a PHP flavour for $OS_FLAVOUR + $SERVER_FLAVOUR + $PHP_VERSION" 2;
fi
if [ -z "${TARGET_IMAGE:+x}" ]; then
  read -ra TARGET_IMAGES <<<"$(get_target_images "$PHP_FLAVOUR" "$PS_VERSION" "$PHP_VERSION" "$OS_FLAVOUR")"
else
  read -ra TARGET_IMAGES <<<"-t $TARGET_IMAGE"
fi

# Build the docker image
# ----------------------
CACHE_IMAGE=${TARGET_IMAGES[1]}
docker pull "$CACHE_IMAGE" 2> /dev/null || true
docker buildx build \
  --progress=plain \
  --file "./docker/${OS_FLAVOUR}.Dockerfile" \
  --platform "$TARGET_PLATFORM" \
  --cache-from type=registry,ref="$CACHE_IMAGE" \
  --cache-to type=inline \
  --build-arg PHP_FLAVOUR="$PHP_FLAVOUR" \
  --build-arg PS_VERSION="$PS_VERSION" \
  --build-arg PHP_VERSION="$PHP_VERSION" \
  --build-arg GIT_SHA="$GIT_SHA" \
  --build-arg NODE_VERSION="$NODE_VERSION" \
  --label org.opencontainers.image.title="PrestaShop Flashlight" \
  --label org.opencontainers.image.description="PrestaShop Flashlight testing utility" \
  --label org.opencontainers.image.source=https://github.com/PrestaShop/prestashop-flashlight \
  --label org.opencontainers.image.url=https://github.com/PrestaShop/prestashop-flashlight \
  --label org.opencontainers.image.licenses=MIT \
  --label org.opencontainers.image.created="$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")" \
  "${TARGET_IMAGES[@]}" \
  "$([ "${PUSH}" == "true" ] && echo "--push" || echo "--load")" \
  .
