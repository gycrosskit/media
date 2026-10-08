#!/usr/bin/env bash
set -euo pipefail
# 只在临时 GitHub runner 复用本 job 已经通过原域名 HTTPS 验证的地址。
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted || ! "${RUNNER_OS:-}" =~ ^(Linux|macOS)$ ]]; then
    echo "CI fork host reuse skipped outside temporary GitHub-hosted runner"
    exit 0
fi
ci_dns_host=maven.eazytec-cloud.com
ci_probe_dir="$(mktemp -d)"
trap 'rm -rf "$ci_probe_dir"' EXIT
ci_marker_url="https://$ci_dns_host/nexus/repository/maven-public/org/jetbrains/kotlin/multiplatform/org.jetbrains.kotlin.multiplatform.gradle.plugin/2.2.21-1.0.0/org.jetbrains.kotlin.multiplatform.gradle.plugin-2.2.21-1.0.0.pom"
ci_curl=(curl --disable --fail --silent --show-error --proto '=https' --ipv4 --noproxy "$ci_dns_host,cloudflare-dns.com" --connect-timeout 20 --max-time 60)
ci_probe_error=1
ci_expected_address=""
ci_fallback_address=""
if [[ -n "${CI_FORK_HOST_FALLBACK_IP:-}" ]]; then
    if ! ci_fallback_address="$(python3 - "$CI_FORK_HOST_FALLBACK_IP" <<'PYTHON'
import ipaddress, sys
try:
    address = ipaddress.IPv4Address(sys.argv[1])
    if not address.is_global or address.is_multicast:
        sys.exit(1)
    print(address)
except ipaddress.AddressValueError:
    sys.exit(1)
PYTHON
    )"; then
        echo "CI fork configured fallback is not a public IPv4; skipped"
    fi
fi
ci_connect_error=false
for ci_attempt in 1 2 3; do
    # 不 follow redirect；remote_ip 必须来自原 HTTPS 主机，而非代理或别的域名。
    if ci_probe="$("${ci_curl[@]}" --output "$ci_probe_dir/marker.pom" --write-out '%{http_code} %{remote_ip} %{time_connect}' "$ci_marker_url")"; then
        ci_probe_error=0
        ci_connect_error=false
        break
    else
        ci_probe_error=$?
    fi
    echo "CI fork HTTPS address probe failed (attempt $ci_attempt/3, curl exit $ci_probe_error)"
    # 28 也可能是 TLS/读取超时；仅尚未建立 TCP 的失败可以换地址。
    ci_connect_error=false
    if [[ "$ci_probe_error" == 6 || "$ci_probe_error" == 7 || ( "$ci_probe_error" == 28 && "${ci_probe##* }" == 0.000000 ) ]]; then
        ci_connect_error=true
    fi
    if [[ "$ci_connect_error" != true || -n "$ci_fallback_address" ]]; then break; fi
    if [[ "$ci_attempt" != 3 ]]; then sleep 2; fi
done
if [[ "$ci_connect_error" == true && -n "$ci_fallback_address" ]]; then
    # 受控 CI 配置只提供候选；每个 job 仍验证原域名证书、HTTP 200 和实际地址。
    ci_expected_address="$ci_fallback_address"
    if ci_probe="$("${ci_curl[@]}" --resolve "$ci_dns_host:443:$ci_expected_address" --output "$ci_probe_dir/marker.pom" --write-out '%{http_code} %{remote_ip} %{time_connect}' "$ci_marker_url")"; then
        ci_probe_error=0
    else
        ci_probe_error=$?
        echo "CI fork configured fallback probe failed (curl exit $ci_probe_error)"
    fi
fi
if [[ "$ci_probe_error" == 6 ]]; then
    echo "CI system DNS unavailable; trying one Cloudflare DoH A query"
    ci_probe_error=1
    if ci_doh_status="$("${ci_curl[@]}" --header 'Accept: application/dns-json' --output "$ci_probe_dir/doh.json" --write-out '%{http_code}' "https://cloudflare-dns.com/dns-query?name=$ci_dns_host&type=A")"; then
        if [[ "$ci_doh_status" == 200 ]] && ci_expected_address="$(python3 - "$ci_probe_dir/doh.json" "$ci_dns_host" <<'PYTHON'
import ipaddress, json, sys
try:
    with open(sys.argv[1]) as source:
        data = json.load(source)
    host = sys.argv[2]
    questions = data.get('Question', [])
    if type(data.get('Status')) is not int or data['Status'] != 0 or len(questions) != 1 or type(questions[0].get('type')) is not int or questions[0]['type'] != 1 or questions[0].get('name', '').rstrip('.').lower() != host:
        sys.exit(1)
    for answer in data.get('Answer', []):
        if type(answer.get('type')) is not int or answer['type'] != 1 or answer.get('name', '').rstrip('.').lower() != host:
            continue
        address = ipaddress.IPv4Address(answer.get('data', ''))
        if address.is_global and not address.is_multicast:
            print(address)
            sys.exit(0)
except (OSError, ValueError, TypeError, AttributeError):
    pass
sys.exit(1)
PYTHON
        )"; then
            # DoH 答案不代表产物可用；仍须原域名完整 TLS、200 和实际候选地址一致。
            if ci_probe="$("${ci_curl[@]}" --resolve "$ci_dns_host:443:$ci_expected_address" --output "$ci_probe_dir/marker.pom" --write-out '%{http_code} %{remote_ip} %{time_connect}' "$ci_marker_url")"; then
                ci_probe_error=0
            fi
        fi
    fi
fi
if [[ "$ci_probe_error" == 0 ]] && ci_address="$(python3 - "$ci_probe" "$ci_expected_address" <<'PYTHON'
import ipaddress, sys
parts = sys.argv[1].split()
if len(parts) != 3 or parts[0] != '200' or (sys.argv[2] and parts[1] != sys.argv[2]):
    sys.exit(1)
try:
    address = ipaddress.IPv4Address(parts[1])
except ipaddress.AddressValueError:
    sys.exit(1)
if not address.is_global or address.is_multicast:
    sys.exit(1)
print(address)
PYTHON
)"; then
    if printf '%s %s\n' "$ci_address" "$ci_dns_host" | sudo tee -a /etc/hosts >/dev/null; then
        echo "CI fork HTTPS verified; job host address reused: $ci_dns_host $ci_address"
    else
        echo "CI fork host write unavailable; continuing normal Gradle resolution"
    fi
else
    # 探测/备用解析不能替代验收门禁；真实 Gradle 下载/编译仍决定成败。
    echo "CI fork host reuse unavailable; continuing normal Gradle resolution"
fi
