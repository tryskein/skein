// s3check: checks an S3-compatible endpoint against what skein-api needs from object storage.
// Logic of presigning mirrors skein-api internal/attachments/client.go (minio-go v7.1.0).
// Output: one line per check: PASS|FAIL|SKIP <id> <name> <detail>. Exit 1 if any FAIL.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/cors"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

var lastHdr http.Header

var (
	ctx      = context.Background()
	bucket   = env("S3_BUCKET", "skein-attachments")
	region   = env("S3_REGION", "us-east-1")
	origin   = env("S3_ORIGIN", "http://localhost:8080")
	secure   = env("S3_SECURE", "") == "1"
	ak, sk   = env("S3_ACCESS_KEY", ""), env("S3_SECRET_KEY", "")
	ep       = env("S3_ENDPOINT", "")
	pubEP    = env("S3_PUBLIC_ENDPOINT", ep)
	failures int
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func mk(endpoint, a, s, reg string) *minio.Client {
	c, err := minio.New(endpoint, &minio.Options{Creds: credentials.NewStaticV4(a, s, ""), Secure: secure, Region: reg})
	if err != nil {
		panic(err)
	}
	return c
}

func out(status, id, name, detail string) {
	if status == "FAIL" {
		failures++
	}
	detail = strings.Join(strings.Fields(detail), " ")
	fmt.Printf("%s %s %s %s\n", status, id, name, detail)
}
func res(ok bool, id, name, detail string) {
	if ok {
		out("PASS", id, name, detail)
	} else {
		out("FAIL", id, name, detail)
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func presignPost(c *minio.Client, key, ct string, size int64, ttl time.Duration) (*url.URL, map[string]string) {
	p := minio.NewPostPolicy()
	must(p.SetBucket(bucket))
	must(p.SetKey(key))
	must(p.SetExpires(time.Now().UTC().Add(ttl)))
	must(p.SetContentType(ct))
	must(p.SetContentLengthRange(size, size))
	u, f, err := c.PresignedPostPolicy(ctx, p)
	must(err)
	return u, f
}

func presignGet(c *minio.Client, key, fn string, ttl time.Duration) string {
	rp := make(url.Values)
	if fn != "" {
		rp.Set("response-content-disposition", dispo(fn))
	}
	u, err := c.PresignedGetObject(ctx, bucket, key, ttl, rp)
	must(err)
	return u.String()
}

func dispo(fn string) string {
	return fmt.Sprintf(`attachment; filename="%s"; filename*=UTF-8''%s`, asciiFallback(fn), rfc5987(fn))
}

func asciiFallback(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 0x20 && r < 0x7f {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

func rfc5987(s string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte("!#$&+-.^_`|~", c) >= 0 {
			b.WriteByte(c)
		} else {
			b.WriteByte('%')
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&15])
		}
	}
	return b.String()
}

// rnd yields n non-repeating pseudo-random bytes (incompressible, no block dedup).
type rnd struct {
	n int64
	s uint64
}

func newRnd(n int64) *rnd { return &rnd{n: n, s: uint64(time.Now().UnixNano()) | 1} }
func (z *rnd) Read(p []byte) (int, error) {
	if z.n <= 0 {
		return 0, io.EOF
	}
	if int64(len(p)) > z.n {
		p = p[:z.n]
	}
	for i := range p {
		z.s ^= z.s << 13
		z.s ^= z.s >> 7
		z.s ^= z.s << 17
		p[i] = byte(z.s)
	}
	z.n -= int64(len(p))
	return len(p), nil
}

// browser-style multipart POST: policy fields first, file part last, explicit Content-Length.
func post(u *url.URL, fields, ov map[string]string, size int64) (int, string) {
	var head bytes.Buffer
	w := multipart.NewWriter(&head)
	for k, v := range fields {
		if o, ok := ov[k]; ok {
			v = o
			if o == "\x00DEL" {
				continue
			}
		}
		must(w.WriteField(k, v))
	}
	_, err := w.CreateFormFile("file", "x.bin")
	must(err)
	tail := []byte("\r\n--" + w.Boundary() + "--\r\n")
	req, _ := http.NewRequest("POST", u.String(), io.MultiReader(&head, newRnd(size), bytes.NewReader(tail)))
	req.ContentLength = int64(head.Len()) + size + int64(len(tail))
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.Header.Set("Origin", origin)
	resp, err := (&http.Client{Timeout: 30 * time.Minute}).Do(req)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	lastHdr = resp.Header
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 400))
	return resp.StatusCode, string(b)
}

func has(c *minio.Client, key string) bool {
	_, err := c.StatObject(ctx, bucket, key, minio.StatObjectOptions{})
	return err == nil
}

func upload(c *minio.Client, key, ct string, n int64, ttl time.Duration, ov map[string]string, sz int64) (int, string) {
	u, f := presignPost(c, key, ct, n, ttl)
	return post(u, f, ov, sz)
}

func main() {
	if ep == "" || ak == "" {
		fmt.Println("need S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY (see README)")
		os.Exit(2)
	}
	cmd := "check"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	internal, public := mk(ep, ak, sk, region), mk(pubEP, ak, sk, region)
	switch cmd {
	case "check":
		check(internal, public)
		if failures > 0 {
			os.Exit(1)
		}
	case "setcors":
		fmt.Println("SetBucketCors:", setCors(internal))
	case "mkbucket":
		fmt.Println("MakeBucket:", internal.MakeBucket(ctx, bucket, minio.MakeBucketOptions{}))
	case "extra":
		extra(internal, public)
	case "big":
		big(internal)
	case "listload":
		listload(internal)
	case "rm":
		for _, k := range os.Args[2:] {
			fmt.Println("rm", k, internal.RemoveObject(ctx, bucket, k, minio.RemoveObjectOptions{}))
		}
	case "rw": // rw <key>: PUT/STAT/GET through the single endpoint (node-down probing)
		rw(internal, os.Args[2])
	case "stat":
		_, err := internal.StatObject(ctx, bucket, os.Args[2], minio.StatObjectOptions{})
		fmt.Println("stat", os.Args[2], "err:", err)
	}
}

func setCors(c *minio.Client) error {
	return c.SetBucketCors(ctx, bucket, &cors.Config{CORSRules: []cors.Rule{{
		AllowedOrigin: []string{origin}, AllowedMethod: []string{"GET", "HEAD", "POST", "PUT"},
		AllowedHeader: []string{"*"}, ExposeHeader: []string{"ETag", "Content-Disposition"}, MaxAgeSeconds: 3000}}})
}

func check(c, pub *minio.Client) {
	const size = int64(1024)
	keys := []string{}
	defer func() {
		for _, k := range keys {
			c.RemoveObject(ctx, bucket, k, minio.RemoveObjectOptions{})
		}
	}()
	pfx := "s3check/" + strconv.FormatInt(time.Now().Unix(), 10) + "/"
	K := func(n string) string { k := pfx + n; keys = append(keys, k); return k }

	// 1
	k1 := K("a1")
	st, b := upload(pub, k1, "image/png", size, time.Minute, nil, size)
	res(st == 204 && has(c, k1), "1", "post-exact-size", fmt.Sprintf("status=%d body=%q", st, b))
	// 2
	kp, km := K("b+"), K("b-")
	s1, b1 := upload(pub, kp, "image/png", size, time.Minute, nil, size+1)
	s2, b2 := upload(pub, km, "image/png", size, time.Minute, nil, size-1)
	res(s1 >= 400 && s2 >= 400 && !has(c, kp) && !has(c, km), "2", "post-size-plus-minus-1-rejected", fmt.Sprintf("+1: status=%d %q | -1: status=%d %q | stored=%v/%v", s1, b1, s2, b2, has(c, kp), has(c, km)))
	// 3
	kc, kd, kd2 := K("c"), K("d"), K("d-other")
	s1, b1 = upload(pub, kc, "image/png", size, time.Minute, map[string]string{"Content-Type": "text/html"}, size)
	s2, b2 = upload(pub, kd, "image/png", size, time.Minute, map[string]string{"key": kd2}, size)
	res(s1 >= 400 && s2 >= 400 && !has(c, kc) && !has(c, kd) && !has(c, kd2), "3", "post-wrong-contenttype-and-key-rejected", fmt.Sprintf("ct: status=%d %q | key: status=%d %q", s1, b1, s2, b2))
	// 4
	ke := K("e")
	u, f := presignPost(pub, ke, "image/png", size, 2*time.Second)
	time.Sleep(4 * time.Second)
	st, b = post(u, f, nil, size)
	res(st >= 400 && !has(c, ke), "4", "post-expired-policy-rejected", fmt.Sprintf("status=%d %q", st, b))
	// T: tampered policy / wrong signature
	kt1, kt2 := K("t-policy"), K("t-sig")
	ut, ff := presignPost(pub, kt1, "image/png", size, time.Minute)
	pb := []byte(ff["policy"])
	if pb[10] == 'A' {
		pb[10] = 'B'
	} else {
		pb[10] = 'A'
	}
	sa, ba := post(ut, ff, map[string]string{"policy": string(pb)}, size)
	us, fs := presignPost(pub, kt2, "image/png", size, time.Minute)
	sg := []byte(fs["x-amz-signature"])
	if sg[0] == '0' {
		sg[0] = '1'
	} else {
		sg[0] = '0'
	}
	sb, bb := post(us, fs, map[string]string{"x-amz-signature": string(sg)}, size)
	res(sa >= 400 && sb >= 400 && !has(c, kt1) && !has(c, kt2), "T", "post-tampered-policy-and-signature-rejected", fmt.Sprintf("policy-byte: status=%d %q | signature: status=%d %q", sa, ba, sb, bb))
	// 5
	fn := "Отчёт за квартал №1.pdf"
	resp, err := http.Get(presignGet(pub, k1, fn, time.Minute))
	if err != nil {
		res(false, "5", "get-cyrillic-disposition", err.Error())
	} else {
		d, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		got := resp.Header.Get("Content-Disposition")
		res(resp.StatusCode == 200 && int64(len(d)) == size && got == dispo(fn), "5", "get-cyrillic-disposition", fmt.Sprintf("status=%d len=%d got=%s", resp.StatusCode, len(d), got))
	}
	// 6
	corsCheck(c, pub, K)
	// 7
	_, e1 := c.StatObject(ctx, bucket, k1, minio.StatObjectOptions{})
	_, e2 := c.StatObject(ctx, bucket, pfx+"missing", minio.StatObjectOptions{})
	var er minio.ErrorResponse
	errors.As(e2, &er)
	res(e1 == nil && e2 != nil, "7", "stat-existing-missing", fmt.Sprintf("existing err=%v | missing err=%v code=%s http=%d", e1, e2, er.Code, er.StatusCode))
	// 8
	r1 := c.RemoveObject(ctx, bucket, k1, minio.RemoveObjectOptions{})
	r2 := c.RemoveObject(ctx, bucket, k1, minio.RemoveObjectOptions{})
	r3 := c.RemoveObject(ctx, bucket, pfx+"never", minio.RemoveObjectOptions{})
	res(r1 == nil && r2 == nil && r3 == nil && !has(c, k1), "8", "remove-existing-missing-no-error", fmt.Sprintf("%v %v %v", r1, r2, r3))
	// 9
	const n = 300
	lk := func(i int) string { return fmt.Sprintf("%sl/p%d/i%d/a%d/f-%03d.txt", pfx, i%7, i%13, i, i) }
	for i := 0; i < n; i++ {
		_, err := c.PutObject(ctx, bucket, lk(i), strings.NewReader("x"), 1, minio.PutObjectOptions{})
		must(err)
	}
	seen, total := map[string]bool{}, 0
	var lerr error
	for o := range c.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: "", Recursive: true}) {
		if o.Err != nil {
			lerr = o.Err
			break
		}
		total++
		if strings.HasPrefix(o.Key, pfx+"l/") {
			seen[o.Key] = true
		}
	}
	sub := 0
	for o := range c.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: pfx + "l/p3/", Recursive: true}) {
		must(o.Err)
		sub++
	}
	want := 0
	for i := 0; i < n; i++ {
		if i%7 == 3 {
			want++
		}
	}
	res(lerr == nil && len(seen) == n && sub == want, "9", "list-recursive-300", fmt.Sprintf("prefix='' total=%d ours=%d/%d | prefix p3: %d/%d err=%v", total, len(seen), n, sub, want, lerr))
	for i := 0; i < n; i++ {
		c.RemoveObject(ctx, bucket, lk(i), minio.RemoveObjectOptions{})
	}
	// 10
	ex, e1 := c.BucketExists(ctx, bucket)
	ex2, e2x := c.BucketExists(ctx, "s3check-nonexistent-bucket")
	em := c.MakeBucket(ctx, bucket, minio.MakeBucketOptions{})
	er = minio.ErrorResponse{}
	errors.As(em, &er)
	okMake := em == nil || er.Code == "BucketAlreadyOwnedByYou" || er.Code == "BucketAlreadyExists"
	lb, el := c.ListBuckets(ctx)
	enew := c.MakeBucket(ctx, "s3check-newbucket-"+strconv.FormatInt(time.Now().Unix(), 10), minio.MakeBucketOptions{})
	var er2 minio.ErrorResponse
	errors.As(enew, &er2)
	extra := fmt.Sprintf("MakeBucket(new, main key)=%v code=%s http=%d", enew, er2.Code, er2.StatusCode)
	if enew == nil {
		extra += " (created; remove it manually)"
	}
	if lak := os.Getenv("S3_LIMITED_ACCESS_KEY"); lak != "" {
		l := mk(ep, lak, os.Getenv("S3_LIMITED_SECRET_KEY"), region)
		e := l.MakeBucket(ctx, "s3check-newbucket-lim-"+strconv.FormatInt(time.Now().Unix(), 10), minio.MakeBucketOptions{})
		var e3 minio.ErrorResponse
		errors.As(e, &e3)
		bx, be := l.BucketExists(ctx, bucket)
		extra += fmt.Sprintf(" | limited key: MakeBucket(new)=%v code=%s http=%d, BucketExists(existing)=%v/%v", e, e3.Code, e3.StatusCode, bx, be)
	}
	res(ex && e1 == nil && !ex2 && e2x == nil && okMake && el == nil && len(lb) >= 1, "10", "bucket-exists-make-list",
		fmt.Sprintf("exists=%v/%v missing=%v/%v MakeBucket(existing)=%v code=%s buckets=%d | %s", ex, e1, ex2, e2x, em, er.Code, len(lb), extra))
	// 11
	kr := K("region")
	_, ep1 := c.PutObject(ctx, bucket, kr, strings.NewReader("r"), 1, minio.PutObjectOptions{})
	_, ep2 := c.StatObject(ctx, bucket, kr, minio.StatObjectOptions{})
	_, ep3 := c.ListBuckets(ctx)
	other := mk(ep, ak, sk, "eu-west-1")
	_, eo := other.StatObject(ctx, bucket, kr, minio.StatObjectOptions{})
	res(ep1 == nil && ep2 == nil && ep3 == nil, "11", "region-signature-accepted", fmt.Sprintf("region=%s put=%v stat=%v list=%v | (info) signing as eu-west-1: stat err=%v", region, ep1, ep2, ep3, eo))
	// 12
	nodes := strings.Split(os.Getenv("S3_NODES"), ",")
	if len(nodes) < 2 || nodes[0] == "" {
		out("SKIP", "12", "cross-node-read", "single endpoint; set S3_NODES=host1:port,host2:port for cluster")
	} else {
		xnode(nodes[0], nodes[1], pfx)
	}
}

func corsCheck(c, pub *minio.Client, K func(string) string) {
	note := ""
	if os.Getenv("S3_SET_CORS") == "1" {
		note = fmt.Sprintf("SetBucketCors=%v; ", setCors(c))
	}
	kc := K("cors")
	c.PutObject(ctx, bucket, kc, strings.NewReader("hello"), 5, minio.PutObjectOptions{})
	gu := presignGet(pub, kc, "x.bin", time.Minute)
	pu, _ := presignPost(pub, K("cors-post"), "image/png", 10, time.Minute)
	do := func(method, u string, hdr map[string]string) (int, http.Header) {
		r, _ := http.NewRequest(method, u, nil)
		for k, v := range hdr {
			r.Header.Set(k, v)
		}
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			return 0, http.Header{}
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return resp.StatusCode, resp.Header
	}
	ac := func(h http.Header) string {
		var p []string
		for k, v := range h {
			if strings.HasPrefix(strings.ToLower(k), "access-control") {
				p = append(p, k+"="+strings.Join(v, ","))
			}
		}
		return strings.Join(p, ";")
	}
	s1, h1 := do("OPTIONS", pu.String(), map[string]string{"Origin": origin, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"})
	s2, h2 := do("OPTIONS", gu, map[string]string{"Origin": origin, "Access-Control-Request-Method": "GET"})
	s3, h3 := do("GET", gu, map[string]string{"Origin": origin})
	s4, h4 := do("GET", gu, map[string]string{"Origin": "http://evil.example"})
	ok := h1.Get("Access-Control-Allow-Origin") == origin && h2.Get("Access-Control-Allow-Origin") == origin && h3.Get("Access-Control-Allow-Origin") == origin
	res(ok, "6", "cors-preflight-and-origin", fmt.Sprintf("%spreflight-POST %d {%s} | preflight-GET %d {%s} | GET+Origin %d {%s} | GET foreign-origin %d {%s}", note, s1, ac(h1), s2, ac(h2), s3, ac(h3), s4, ac(h4)))
}

func xnode(w, r, pfx string) {
	cw, cr := mk(w, ak, sk, region), mk(r, ak, sk, region)
	size := int64(2048)
	key := pfx + "xnode"
	st, _ := upload(cw, key, "image/png", size, time.Minute, nil, size)
	_, e1 := cr.StatObject(ctx, bucket, key, minio.StatObjectOptions{})
	_, e2 := cr.StatObject(ctx, bucket, pfx+"xmissing", minio.StatObjectOptions{})
	resp, err := http.Get(presignGet(cr, key, "Файл.png", time.Minute))
	var d []byte
	var cd string
	code := 0
	if err == nil {
		d, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		cd, code = resp.Header.Get("Content-Disposition"), resp.StatusCode
	}
	x1 := cr.RemoveObject(ctx, bucket, key, minio.RemoveObjectOptions{})
	x2 := cr.RemoveObject(ctx, bucket, key, minio.RemoveObjectOptions{})
	_, ew := cw.StatObject(ctx, bucket, key, minio.StatObjectOptions{})
	res(st == 204 && e1 == nil && e2 != nil && code == 200 && int64(len(d)) == size && cd == dispo("Файл.png") && x1 == nil && x2 == nil && ew != nil, "12", "cross-node-read",
		fmt.Sprintf("write via %s post=%d; read via %s: stat=%v missing=%v get=%d len=%d cd-ok=%v remove=%v/%v stat-on-writer-after=%v (node-down: use `rw`, see README)", w, st, r, e1, e2 != nil, code, len(d), cd == dispo("Файл.png"), x1, x2, ew != nil))
}

func big(c *minio.Client) {
	size := int64(500 * 1024 * 1024)
	reps, _ := strconv.Atoi(env("REPS", "1"))
	for i := 0; i < reps; i++ {
		key := fmt.Sprintf("s3check-big/%d.bin", i)
		t0 := time.Now()
		st, b := upload(c, key, "application/octet-stream", size, 30*time.Minute, nil, size)
		d := time.Since(t0)
		oi, err := c.StatObject(ctx, bucket, key, minio.StatObjectOptions{})
		res(st == 204 && err == nil && oi.Size == size, "L", "post-500MB", fmt.Sprintf("rep=%d status=%d %q elapsed=%s size=%d err=%v", i, st, b, d, oi.Size, err))
		if env("KEEP", "") == "" || i < reps-1 {
			c.RemoveObject(ctx, bucket, key, minio.RemoveObjectOptions{})
		}
	}
}

func listload(c *minio.Client) {
	for i := 0; i < 200; i++ {
		_, err := c.PutObject(ctx, bucket, fmt.Sprintf("s3check-ll/%03d", i), strings.NewReader("x"), 1, minio.PutObjectOptions{})
		must(err)
	}
	t0 := time.Now()
	cnt := 0
	for r := 0; r < 300; r++ {
		cnt = 0
		for o := range c.ListObjects(ctx, bucket, minio.ListObjectsOptions{Prefix: "s3check-ll/", Recursive: true}) {
			must(o.Err)
			cnt++
		}
	}
	fmt.Println("300 recursive lists, objects per list:", cnt, "took", time.Since(t0))
	for i := 0; i < 200; i++ {
		c.RemoveObject(ctx, bucket, fmt.Sprintf("s3check-ll/%03d", i), minio.RemoveObjectOptions{})
	}
}

func rw(c *minio.Client, key string) {
	cx, cancel := context.WithTimeout(ctx, 40*time.Second)
	defer cancel()
	t0 := time.Now()
	_, err := c.PutObject(cx, bucket, key, strings.NewReader("hello"), 5, minio.PutObjectOptions{})
	fmt.Printf("PUT %s err=%v (%s)\n", key, err, time.Since(t0).Round(time.Millisecond))
	t0 = time.Now()
	_, err = c.StatObject(cx, bucket, key, minio.StatObjectOptions{})
	fmt.Printf("STAT %s err=%v (%s)\n", key, err, time.Since(t0).Round(time.Millisecond))
	t0 = time.Now()
	o, err := c.GetObject(cx, bucket, key, minio.GetObjectOptions{})
	var d []byte
	if err == nil {
		d, err = io.ReadAll(o)
	}
	fmt.Printf("GET %s data=%q err=%v (%s)\n", key, d, err, time.Since(t0).Round(time.Millisecond))
}

// extra: POST response CORS headers (XHR-style), and POST with required policy fields omitted.
func extra(c, pub *minio.Client) {
	const size = int64(512)
	pfx := "s3extra/" + strconv.FormatInt(time.Now().Unix(), 10) + "/"
	k := pfx + "cors"
	st, _ := upload(pub, k, "image/png", size, time.Minute, nil, size)
	var p []string
	for h, v := range lastHdr {
		if strings.HasPrefix(strings.ToLower(h), "access-control") {
			p = append(p, h+"="+strings.Join(v, ","))
		}
	}
	res(st == 204, "X1", "post-response-cors-headers", fmt.Sprintf("status=%d %s", st, strings.Join(p, ";")))
	k2 := pfx + "noct"
	st, b := upload(pub, k2, "image/png", size, time.Minute, map[string]string{"Content-Type": "\x00DEL"}, size)
	res(st >= 400 && !has(c, k2), "X2", "post-without-content-type-field-rejected", fmt.Sprintf("status=%d %q stored=%v", st, b, has(c, k2)))
	k3 := pfx + "nokey"
	st, b = upload(pub, k3, "image/png", size, time.Minute, map[string]string{"key": "\x00DEL"}, size)
	res(st >= 400 && !has(c, k3), "X3", "post-without-key-field-rejected", fmt.Sprintf("status=%d %q stored=%v", st, b, has(c, k3)))
	k4 := pfx + "nopolicy"
	st, b = upload(pub, k4, "image/png", size, time.Minute, map[string]string{"policy": "\x00DEL"}, size)
	res(st >= 400 && !has(c, k4), "X4", "post-without-policy-field-rejected", fmt.Sprintf("status=%d %q stored=%v", st, b, has(c, k4)))
	k5 := pfx + "bucketother"
	st, b = upload(pub, k5, "image/png", size, time.Minute, map[string]string{"bucket": "s3check-other"}, size)
	res(st >= 400 && !has(c, k5), "X5", "post-wrong-bucket-field-rejected", fmt.Sprintf("status=%d %q stored=%v", st, b, has(c, k5)))
	c.RemoveObject(ctx, bucket, k, minio.RemoveObjectOptions{})
}
