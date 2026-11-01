# Edit a copy of the Talon worker: the Memo keeps List(Jwk.Key) (the first reference of slice 108b, P1).
import sys, re
w = sys.argv[1]
p = w + '/lib/Oidc.roc'; s = open(p).read()
s = s.replace('KeySet : { fetched_ms : U64, jwks : Str }', 'KeySet : { fetched_ms : U64, keys : List(Jwk.Key) }')
s = s.replace('list = Jwk.parse_set(keys.jwks) ?? []', 'list = keys.keys')
open(p, 'w').write(s)
p = w + '/Auth.roc'; s = open(p).read()
s = s.replace('_keys = Jwk.parse_set(text) ? |_| Oidc.jwks_bad\n\t\t\tOk({ fetched_ms: Time.now_ms!(), jwks: text })',
              'keys = Jwk.parse_set(text) ? |_| Oidc.jwks_bad\n\t\t\tOk({ fetched_ms: Time.now_ms!(), keys })')
open(p, 'w').write(s)
