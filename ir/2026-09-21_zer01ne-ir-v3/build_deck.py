import json,re,base64,sys
D='/Users/minsungpark/.aside/u/0/sessions/2026-09-21_kfEY67jjvd8UuhGM/tmp/deck/'
parts=['part1_head.html','part2_main_a.html','part3_s5.html','part4_main_b.html','part5_main_c.html','part6_appx.html','part7_js.html']
html=''.join(open(D+p,encoding='utf-8').read() for p in parts)
logos=json.load(open('/Users/minsungpark/.aside/u/0/sessions/2026-09-17_9dVbeRjfkKV03XRb/tmp/logoB64.json'))
photos=json.load(open('/Users/minsungpark/.aside/u/0/sessions/2026-09-21_kfEY67jjvd8UuhGM/tmp/v1_photos.json'))
def mime(b64):
    return 'image/png' if b64.startswith('iVBOR') else 'image/jpeg' if b64.startswith('/9j/') else 'image/svg+xml' if b64.startswith('PHN2') else 'image/webp'
missing=set()
def rep_logo(m):
    k=m.group(1)
    if k not in logos: missing.add(k); return ''
    v=logos[k]
    return v if v.startswith('data:') else f'data:{mime(v)};base64,{v}'
html=re.sub(r'\{\{LOGO_([a-z0-9]+)\}\}',rep_logo,html)
html=html.replace('{{PHOTO_team}}',photos['team']).replace('{{PHOTO_core}}',photos['ARCA Core'])
fp=json.load(open('/Users/minsungpark/.aside/u/0/sessions/2026-09-21_kfEY67jjvd8UuhGM/tmp/founder_photos.json'))
for k,v in fp.items(): html=html.replace('{{PHOTO_'+k+'}}',v)
left=re.findall(r'\{\{[A-Z_a-z0-9]+\}\}',html)
print('missing logos:',missing,'leftover placeholders:',left)
out=sys.argv[1] if len(sys.argv)>1 else D+'index.html'
open(out,'w',encoding='utf-8').write(html)
print('wrote',out,len(html))
