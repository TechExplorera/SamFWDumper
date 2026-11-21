// uploader: servicio personal de subida de archivos (estilo transfer.sh).
// Solo librería estándar de Go. Metadatos en JSON junto a cada archivo.
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web/index.html
var webFS embed.FS

type Config struct {
	Listen      string
	DataDir     string
	BaseURL     string
	Token       string
	MaxSize     int64
	DefaultDays int
	MaxDays     int
}

type Meta struct {
	ID           string    `json:"id"`
	Name         string    `json:"name"`
	Size         int64     `json:"size"`
	ContentType  string    `json:"content_type"`
	Created      time.Time `json:"created"`
	Expires      time.Time `json:"expires"`
	MaxDownloads int       `json:"max_downloads"` // 0 = ilimitado
	Downloads    int       `json:"downloads"`
	DeleteToken  string    `json:"delete_token"`
}

type Server struct {
	cfg Config
	mu  sync.Mutex // protege lectura/escritura de metadatos
}

var (
	idRe        = regexp.MustCompile(`^[A-Za-z0-9]{8}$`)
	badNameRe   = regexp.MustCompile(`[^A-Za-z0-9._\-+()\[\] ]`)
	base62      = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	errNotFound = errors.New("not found")
)

func main() {
	cfg := Config{
		Listen:      env("LISTEN", ":8080"),
		DataDir:     env("DATA_DIR", "./data"),
		BaseURL:     strings.TrimRight(env("BASE_URL", ""), "/"),
		Token:       os.Getenv("UPLOAD_TOKEN"),
		MaxSize:     envInt64("MAX_SIZE_MB", 10240) << 20,
		DefaultDays: int(envInt64("DEFAULT_DAYS", 7)),
		MaxDays:     int(envInt64("MAX_DAYS", 30)),
	}
	if len(cfg.Token) < 16 {
		log.Fatal("UPLOAD_TOKEN es obligatorio y debe tener al menos 16 caracteres (genera uno: openssl rand -hex 24)")
	}
	if err := os.MkdirAll(cfg.DataDir, 0o750); err != nil {
		log.Fatal(err)
	}

	s := &Server{cfg: cfg}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go s.cleanupLoop(ctx)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           logMW(s.routes()),
		ReadHeaderTimeout: 30 * time.Second,
		// Sin ReadTimeout/WriteTimeout: subidas y descargas grandes pueden tardar horas.
		IdleTimeout: 120 * time.Second,
	}
	go func() {
		<-ctx.Done()
		sh, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(sh)
	}()
	log.Printf("uploader escuchando en %s, datos en %s, máx %d MB", cfg.Listen, cfg.DataDir, cfg.MaxSize>>20)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("POST /{$}", s.handleUploadForm)
	mux.HandleFunc("PUT /{name}", s.handleUploadPut)
	mux.HandleFunc("GET /api/files", s.handleList)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, "ok\n") })
	mux.HandleFunc("GET /{id}/{name}", s.handleDownload)
	mux.HandleFunc("DELETE /{id}/{name}", s.handleDelete)
	mux.HandleFunc("DELETE /{id}", s.handleDelete)
	return mux
}

// ---------- Handlers ----------

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if isCLI(r) {
		base := s.baseURL(r)
		fmt.Fprintf(w, "Uso:\n  curl -H \"Authorization: Bearer $TOKEN\" -T archivo.zip %s/\n"+
			"Cabeceras opcionales: Max-Days: N   Max-Downloads: N\n"+
			"Borrar: curl -X DELETE -H \"X-Delete-Token: <token>\" <url>\n", base)
		return
	}
	b, _ := webFS.ReadFile("web/index.html")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
	w.Write(b)
}

// PUT /nombre  (curl -T)
func (s *Server) handleUploadPut(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "no autorizado\n", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxSize)
	m, err := s.store(r, r.PathValue("name"), r.Header.Get("Content-Type"), r.Body)
	s.respondUpload(w, r, m, err)
}

// POST / multipart, campo "file" (web y curl -F)
func (s *Server) handleUploadForm(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "no autorizado\n", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxSize+(1<<20))
	mr, err := r.MultipartReader()
	if err != nil {
		http.Error(w, "se esperaba multipart/form-data\n", http.StatusBadRequest)
		return
	}
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			http.Error(w, "falta el campo 'file'\n", http.StatusBadRequest)
			return
		}
		if err != nil {
			s.respondUpload(w, r, nil, err)
			return
		}
		if part.FormName() != "file" {
			part.Close()
			continue
		}
		m, err := s.store(r, part.FileName(), part.Header.Get("Content-Type"), part)
		s.respondUpload(w, r, m, err)
		return
	}
}

func (s *Server) respondUpload(w http.ResponseWriter, r *http.Request, m *Meta, err error) {
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			http.Error(w, fmt.Sprintf("archivo demasiado grande (máx %d MB)\n", s.cfg.MaxSize>>20), http.StatusRequestEntityTooLarge)
			return
		}
		log.Printf("error al guardar: %v", err)
		http.Error(w, "error al guardar el archivo\n", http.StatusInternalServerError)
		return
	}
	u := s.fileURL(r, m)
	w.Header().Set("X-Delete-Token", m.DeleteToken)
	w.Header().Set("X-Expires", m.Expires.Format(time.RFC3339))
	if strings.Contains(r.Header.Get("Accept"), "application/json") {
		writeJSON(w, map[string]any{
			"url": u, "delete_token": m.DeleteToken, "size": m.Size,
			"expires": m.Expires, "max_downloads": m.MaxDownloads,
		})
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintln(w, u)
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m, err := s.loadMeta(id)
	if err != nil || m.Name != r.PathValue("name") || s.expired(m) {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(s.blobPath(id))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()

	// Cuenta la descarga solo en GET que empieza desde el byte 0 (no en HEAD ni en reanudaciones).
	if r.Method == http.MethodGet && !isRangeContinuation(r) {
		if !s.countDownload(id) {
			http.NotFound(w, r)
			return
		}
	}

	ct := m.ContentType
	if ct == "" {
		ct = "application/octet-stream"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	disp := "attachment"
	if inlineSafe(ct) && r.URL.Query().Get("dl") == "" {
		disp = "inline"
	}
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disp, map[string]string{"filename": m.Name}))
	w.Header().Set("Content-Security-Policy", "sandbox")
	http.ServeContent(w, r, m.Name, m.Created, f)
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m, err := s.loadMeta(id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	tok := r.Header.Get("X-Delete-Token")
	if !(tok != "" && secureEq(tok, m.DeleteToken)) && !s.authorized(r) {
		http.Error(w, "no autorizado\n", http.StatusUnauthorized)
		return
	}
	s.remove(id)
	io.WriteString(w, "borrado\n")
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "no autorizado\n", http.StatusUnauthorized)
		return
	}
	entries, _ := os.ReadDir(s.cfg.DataDir)
	out := []map[string]any{}
	for _, e := range entries {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok {
			continue
		}
		m, err := s.loadMeta(id)
		if err != nil || s.expired(m) {
			continue
		}
		out = append(out, map[string]any{
			"url": s.fileURL(r, m), "name": m.Name, "size": m.Size,
			"created": m.Created, "expires": m.Expires,
			"downloads": m.Downloads, "max_downloads": m.MaxDownloads,
			"delete_token": m.DeleteToken,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i]["created"].(time.Time).After(out[j]["created"].(time.Time)) })
	writeJSON(w, out)
}

// ---------- Almacenamiento ----------

func (s *Server) store(r *http.Request, name, ctype string, body io.Reader) (*Meta, error) {
	name = sanitizeName(name)
	id, err := newID()
	if err != nil {
		return nil, err
	}
	days := clamp(headerOrQueryInt(r, "Max-Days", "days", s.cfg.DefaultDays), 1, s.cfg.MaxDays)
	maxDl := clamp(headerOrQueryInt(r, "Max-Downloads", "downloads", 0), 0, 1_000_000)

	tmp, err := os.CreateTemp(s.cfg.DataDir, ".upload-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name()) // no-op si ya se renombró
	n, err := io.Copy(tmp, body)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, errors.New("archivo vacío")
	}

	ctype, _, _ = strings.Cut(ctype, ";")
	if ctype == "" || ctype == "application/x-www-form-urlencoded" {
		ctype = mime.TypeByExtension(filepath.Ext(name))
	}
	now := time.Now().UTC()
	m := &Meta{
		ID: id, Name: name, Size: n, ContentType: ctype,
		Created: now, Expires: now.Add(time.Duration(days) * 24 * time.Hour),
		MaxDownloads: maxDl, DeleteToken: randHex(16),
	}
	if err := os.Rename(tmp.Name(), s.blobPath(id)); err != nil {
		return nil, err
	}
	if err := s.saveMeta(m); err != nil {
		os.Remove(s.blobPath(id))
		return nil, err
	}
	log.Printf("subido %s/%s (%d bytes, %d días)", id, name, n, days)
	return m, nil
}

func (s *Server) blobPath(id string) string { return filepath.Join(s.cfg.DataDir, id+".bin") }
func (s *Server) metaPath(id string) string { return filepath.Join(s.cfg.DataDir, id+".json") }

func (s *Server) loadMeta(id string) (*Meta, error) {
	if !idRe.MatchString(id) {
		return nil, errNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadMetaLocked(id)
}

func (s *Server) loadMetaLocked(id string) (*Meta, error) {
	b, err := os.ReadFile(s.metaPath(id))
	if err != nil {
		return nil, errNotFound
	}
	var m Meta
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

func (s *Server) saveMeta(m *Meta) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveMetaLocked(m)
}

func (s *Server) saveMetaLocked(m *Meta) error {
	b, _ := json.MarshalIndent(m, "", "  ")
	tmp := s.metaPath(m.ID) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, s.metaPath(m.ID))
}

// countDownload incrementa el contador; devuelve false si ya se agotó.
func (s *Server) countDownload(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.loadMetaLocked(id)
	if err != nil {
		return false
	}
	if m.MaxDownloads > 0 && m.Downloads >= m.MaxDownloads {
		return false
	}
	m.Downloads++
	if err := s.saveMetaLocked(m); err != nil {
		log.Printf("no se pudo actualizar contador de %s: %v", id, err)
	}
	return true
}

func (s *Server) expired(m *Meta) bool {
	return time.Now().After(m.Expires)
}

func (s *Server) remove(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	os.Remove(s.blobPath(id))
	os.Remove(s.metaPath(id))
}

func (s *Server) cleanupLoop(ctx context.Context) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		s.cleanup()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Server) cleanup() {
	entries, err := os.ReadDir(s.cfg.DataDir)
	if err != nil {
		return
	}
	for _, e := range entries {
		name := e.Name()
		// Temporales huérfanos de subidas interrumpidas (más de 1 día).
		if strings.HasPrefix(name, ".upload-") {
			if info, err := e.Info(); err == nil && time.Since(info.ModTime()) > 24*time.Hour {
				os.Remove(filepath.Join(s.cfg.DataDir, name))
			}
			continue
		}
		id, ok := strings.CutSuffix(name, ".json")
		if !ok {
			continue
		}
		m, err := s.loadMeta(id)
		if err != nil {
			continue
		}
		exhausted := m.MaxDownloads > 0 && m.Downloads >= m.MaxDownloads
		if s.expired(m) || exhausted {
			s.remove(id)
			log.Printf("eliminado %s/%s (caducado o descargas agotadas)", id, m.Name)
		}
	}
}

// ---------- Utilidades ----------

func (s *Server) authorized(r *http.Request) bool {
	tok := r.Header.Get("X-Upload-Token")
	if v, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
		tok = v
	}
	return tok != "" && secureEq(tok, s.cfg.Token)
}

func (s *Server) baseURL(r *http.Request) string {
	if s.cfg.BaseURL != "" {
		return s.cfg.BaseURL
	}
	scheme := "http"
	if r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https" {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func (s *Server) fileURL(r *http.Request, m *Meta) string {
	return s.baseURL(r) + "/" + m.ID + "/" + url.PathEscape(m.Name)
}

func secureEq(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func newID() (string, error) {
	var sb strings.Builder
	max := big.NewInt(int64(len(base62)))
	for i := 0; i < 8; i++ {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		sb.WriteByte(base62[n.Int64()])
	}
	return sb.String(), nil
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func sanitizeName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	name = badNameRe.ReplaceAllString(name, "_")
	name = strings.Trim(name, ". ")
	if name == "" || name == "/" {
		name = "archivo"
	}
	if len(name) > 200 {
		ext := filepath.Ext(name)
		if len(ext) > 20 {
			ext = ""
		}
		name = name[:200-len(ext)] + ext
	}
	return name
}

func inlineSafe(ct string) bool {
	switch {
	case strings.HasPrefix(ct, "image/") && ct != "image/svg+xml":
		return true
	case strings.HasPrefix(ct, "video/"), strings.HasPrefix(ct, "audio/"),
		ct == "text/plain", ct == "application/pdf":
		return true
	}
	return false
}

func isRangeContinuation(r *http.Request) bool {
	rg := r.Header.Get("Range")
	return rg != "" && !strings.HasPrefix(rg, "bytes=0-")
}

func isCLI(r *http.Request) bool {
	ua := strings.ToLower(r.UserAgent())
	return strings.HasPrefix(ua, "curl") || strings.HasPrefix(ua, "wget") || strings.HasPrefix(ua, "httpie")
}

func headerOrQueryInt(r *http.Request, header, query string, def int) int {
	v := r.Header.Get(header)
	if v == "" {
		v = r.URL.Query().Get(query)
	}
	if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
		return n
	}
	return def
}

func clamp(v, lo, hi int) int {
	return min(max(v, lo), hi)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt64(k string, def int64) int64 {
	if n, err := strconv.ParseInt(os.Getenv(k), 10, 64); err == nil && n > 0 {
		return n
	}
	return def
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(c int) { s.code = c; s.ResponseWriter.WriteHeader(c) }

// ReadFrom permite que io.Copy/sendfile sigan siendo eficientes con el wrapper.
func (s *statusRecorder) ReadFrom(r io.Reader) (int64, error) {
	if rf, ok := s.ResponseWriter.(io.ReaderFrom); ok {
		return rf.ReadFrom(r)
	}
	return io.Copy(s.ResponseWriter, r)
}

func logMW(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: 200}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.code, time.Since(start).Round(time.Millisecond))
	})
}
