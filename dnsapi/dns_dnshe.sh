#!/usr/bin/env sh
# shellcheck disable=SC2034
dns_dnshe_info='DNSHE Free Domains
Site: https://www.dnshe.com/
Docs: https://github.com/dnshe/DNSHE-FreeDomains/blob/main/docs/api.md
Options:
 DNSHE_API_KEY API Key
 DNSHE_API_SECRET API Secret
'

dns_dnshe_add() (
  _dnshe_mutate add "$1" "$2"
)

dns_dnshe_rm() (
  _dnshe_mutate remove "$1" "$2"
)

_dnshe_mutate() {
  LC_ALL=C
  export LC_ALL
  # The account helpers can log saved values at high debug levels.
  DEBUG=0
  LOG_LEVEL=0
  SYS_LOG=0
  set -f
  DNSHE_API_KEY="${DNSHE_API_KEY:-$(_readaccountconf_mutable DNSHE_API_KEY)}"
  DNSHE_API_SECRET="${DNSHE_API_SECRET:-$(_readaccountconf_mutable DNSHE_API_SECRET)}"
  for _dnshe_credential in "$DNSHE_API_KEY" "$DNSHE_API_SECRET"; do
    case "$_dnshe_credential" in
    '' | *[![:graph:]]*)
      _err "DNSHE_API_KEY and DNSHE_API_SECRET must be nonempty and contain no whitespace"
      return 1
      ;;
    esac
  done
  _dnshe_name="$(printf '%s' "${2%.}" | _lower_case)"
  _dnshe_value="$3"
  case "$_dnshe_name" in
  '' | *[!a-z0-9_.-]*)
    _err "Invalid DNSHE challenge name"
    return 1
    ;;
  esac
  case "$_dnshe_value" in
  '' | *[!a-zA-Z0-9_-]*)
    _err "Invalid DNSHE challenge value"
    return 1
    ;;
  esac

  _dnshe_zone || return 1
  _dnshe_ids="$(_dnshe_list_matching_records)" || return 1
  if [ "$1" = add ]; then
    _saveaccountconf_mutable DNSHE_API_KEY "$DNSHE_API_KEY" 1
    _saveaccountconf_mutable DNSHE_API_SECRET "$DNSHE_API_SECRET" 1
    if [ -z "$_dnshe_ids" ]; then
      _dnshe_body="{\"subdomain_id\":$_dnshe_zone_id,\"type\":\"TXT\",\"name\":\"$_dnshe_relative\",\"content\":\"$_dnshe_value\"}"
      if ! _dnshe_request dns_records create '' "$_dnshe_body" write; then
        # A lost response can follow a successful create. Check without replaying the POST.
        _dnshe_ids="$(_dnshe_list_matching_records)" || return 1
        [ -n "$_dnshe_ids" ] || return 1
      fi
    fi
    return 0
  fi

  _dnshe_failed=0
  for _dnshe_id in $_dnshe_ids; do
    _dnshe_request dns_records delete '' "{\"id\":$_dnshe_id}" write || _dnshe_failed=1
  done
  return "$_dnshe_failed"
}

_dnshe_list_matching_records() {
  _dnshe_request dns_records list "&subdomain_id=$_dnshe_zone_id" '' records
}

_dnshe_zone() {
  _dnshe_page=1
  _dnshe_zone=
  while [ "$_dnshe_page" -le 100 ]; do
    _dnshe_page_result="$(_dnshe_request subdomains list "&page=$_dnshe_page&per_page=500&fields=id,full_domain,status" '' zones)" || return 1
    set -- $_dnshe_page_result
    if [ "$#" = 4 ] && [ "${#3}" -gt "${#_dnshe_zone}" ]; then
      _dnshe_zone_id="$2"
      _dnshe_zone="$3"
      _dnshe_status="$4"
    fi
    if [ "$1" = 0 ]; then
      if [ -z "$_dnshe_zone" ]; then
        _err "DNSHE account has no managed domain for the challenge"
        return 1
      fi
      if [ "$_dnshe_status" != usable ]; then
        _err "DNSHE managed domain $_dnshe_zone is inactive"
        return 1
      fi
      if [ "$_dnshe_name" = "$_dnshe_zone" ]; then
        _dnshe_relative=@
      else
        _dnshe_relative="${_dnshe_name%."$_dnshe_zone"}"
      fi
      return 0
    fi
    _dnshe_page=$((_dnshe_page + 1))
  done
  _err "DNSHE domain pagination exceeded 100 pages"
  return 1
}

_dnshe_request() (
  # Dedicated HTTP state keeps acme.sh's debug traces and redirects away from custom credentials.
  _resethttp
  DEBUG=0
  ACME_HTTP_NO_REDIRECTS=1
  HTTP_HEADER="$(_mktemp)" || return 1
  trap 'rm -f -- "$HTTP_HEADER"' EXIT
  _inithttp
  if [ -n "$_ACME_CURL" ] && [ "${ACME_USE_WGET:-0}" = 0 ]; then
    # --disable must be the first option to keep curlrc redirects, retries and traces out.
    _ACME_CURL="curl --disable ${_ACME_CURL#curl } --connect-timeout 10 --max-time 30"
  elif [ -n "$_ACME_WGET" ]; then
    _dnshe_wget_help="$(wget --help 2>&1)"
    if _contains "$_dnshe_wget_help" '-T'; then
      _ACME_WGET="$_ACME_WGET -T 30"
    fi
    if _contains "$_dnshe_wget_help" '--tries'; then
      _ACME_WGET="$_ACME_WGET --tries=1"
    fi
    if _contains "$_dnshe_wget_help" '--no-config'; then
      _ACME_WGET="$_ACME_WGET --no-config"
    fi
  fi
  export _H1="X-API-Key: $DNSHE_API_KEY"
  export _H2="X-API-Secret: $DNSHE_API_SECRET"
  export _H3="Accept: application/json"
  unset _H4 _H5
  _dnshe_url="https://api005.dnshe.com/index.php?m=domain_hub&endpoint=$1&action=$2$3"
  _dnshe_transport=0
  if [ -n "$4" ]; then
    _dnshe_response="$(_post "$4" "$_dnshe_url" '' POST application/json)" || _dnshe_transport=$?
  else
    _dnshe_response="$(_get "$_dnshe_url")" || _dnshe_transport=$?
  fi
  _dnshe_http_status="$(sed -n 's/^[[:space:]]*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' "$HTTP_HEADER" | _tail_n 1)"
  _dnshe_parsed="$(printf '%s' "$_dnshe_response" | _dnshe_json "$5")" || _dnshe_parsed=invalid_json
  _dnshe_outcome="$(printf '%s\n' "$_dnshe_parsed" | _head_n 1)"
  case "$_dnshe_http_status:$_dnshe_outcome:$_dnshe_transport" in
  2[0-9][0-9]:ok:0)
    printf '%s\n' "$_dnshe_parsed" | sed '1d'
    return 0
    ;;
  404:dns_record_not_found:*)
    [ "$2" != delete ] || return 0
    ;;
  esac
  _err "DNSHE $1/$2 failed (HTTP ${_dnshe_http_status:-unavailable}, $_dnshe_outcome)"
  return 1
)

# Read only the documented top-level fields and row fields. JSON strings are
# tokenized before interpreting punctuation, including unrelated record values.
_dnshe_json() {
  awk -v mode="$1" -v name="$_dnshe_name" -v zone="${_dnshe_zone:-}" -v value="$_dnshe_value" '
    { input = input $0 "\n" }
    function next_token(    length_used, ch) {
      sub(/^[[:space:]]+/, "", input)
      ch = substr(input, 1, 1)
      string = ""
      if (ch == "\"") {
        if (!match(input, /^"([^"\\[:cntrl:]]|\\(["\\\/bfnrt]|u[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]))*"/)) exit 1
        length_used = RLENGTH
        string = substr(input, 2, length_used - 2)
        token = "string"
      } else if (ch != "" && index("{}[],:", ch)) {
        length_used = 1
        token = ch
      } else if (match(input, /^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([Ee][+-]?[0-9]+)?)/)) {
        length_used = RLENGTH
        token = substr(input, 1, length_used)
      } else {
        if (input != "") exit 1
        token = ""
        return
      }
      input = substr(input, length_used + 1)
    }
    function parse(role, depth,    key, child, item) {
      if (depth > 32) exit 1
      if (role == "list" && token != "[" || role == "row" && token != "{") exit 1
      if (token == "{") {
        if (role == "row") {
          for (item in row) delete row[item]
        }
        next_token()
        if (token != "}") {
          while (1) {
            if (token != "string") exit 1
            key = string
            next_token()
            if (token != ":") exit 1
            next_token()
            child = ""
            if (role == "root" && list_key != "" && key == list_key) child = "list"
            if (role == "root" && key == "pagination") child = "pagination"
            if (role == "root" && key == "success") success = token
            if (role == "root" && key == "error_code" && token == "string") error_code = string
            if (role == "pagination" && key == "has_more") has_more = token
            if (role == "row" && (token == "string" || key == "id" && token ~ /^[0-9]+$/)) row[key] = token == "string" ? string : token
            parse(child, depth + 1)
            if (token != ",") break
            next_token()
          }
        }
        if (token != "}") exit 1
        if (role == "row") collect()
      } else if (token == "[") {
        if (role == "list") found_list = 1
        next_token()
        if (token != "]") {
          while (1) {
            parse(role == "list" ? "row" : "", depth + 1)
            if (token != ",") break
            next_token()
          }
        }
        if (token != "]") exit 1
      } else if (token == "" || index("{}[],:", token)) {
        exit 1
      }
      next_token()
    }
    function inside_zone(name, domain,    prefix_len) {
      prefix_len = length(name) - length(domain)
      return name == domain || (prefix_len > 0 && substr(name, prefix_len) == "." domain)
    }
    function collect(    domain, id, status, record_name, absolute) {
      rows++
      id = row["id"]
      sub(/^0+/, "", id)
      if (mode == "zones") {
        domain = tolower(row["full_domain"])
        sub(/\.+$/, "", domain)
        if (domain !~ /^[a-z0-9.-]+$/ || length(domain) <= length(best)) return
        if (!inside_zone(name, domain)) return
        best = domain
        best_id = id
        status = tolower(row["status"])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
        usable = status == "active" || status == "registered" ? "usable" : "inactive"
      } else {
        if (!("name" in row) || !("content" in row)) return
        record_name = tolower(row["name"])
        absolute = sub(/\.+$/, "", record_name)
        if (!absolute && (record_name == "" || record_name == "@")) record_name = zone
        else if (!absolute && !inside_zone(record_name, zone)) record_name = record_name "." zone
        if (tolower(row["type"]) != "txt" || record_name != name) return
        if (row["content"] != value && row["content"] != "\\\"" value "\\\"") return
        if (id !~ /^[1-9][0-9]*$/) exit 1
        ids[id] = 1
      }
    }
    END {
      list_key = mode == "zones" ? "subdomains" : mode == "records" ? "records" : ""
      next_token()
      if (token != "{") exit 1
      parse("root", 0)
      if (token != "") exit 1
      if (success != "true") {
        if (error_code ~ /^(auth_invalid_credentials|auth_ip_not_allowed|api_access_disabled|dns_record_not_found|subdomain_not_found|external_dns_delegated|quota_exceeded|rate_limit_exceeded)$/) print error_code
        else print "api_error"
        exit
      }
      if (mode != "write" && !found_list) exit 1
      if (mode == "zones") {
        more = has_more == "true" || (has_more != "false" && rows >= 500)
        if (more && !rows || best != "" && best_id !~ /^[1-9][0-9]*$/) exit 1
        print "ok"
        print more ? 1 : 0
        if (best != "") print best_id, best, usable
      } else {
        print "ok"
        for (id in ids) print id
      }
    }
  '
}
