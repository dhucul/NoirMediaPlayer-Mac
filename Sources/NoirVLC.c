// Small, dynamically linked LibVLC 3 adapter. No VideoLAN source is copied here.
#include "NoirVLC.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <pthread.h>
#include <zlib.h>
uint32_t noir_crc32(const void *input,unsigned size) { return (uint32_t)crc32(0,input,size); }
int noir_inflate(const void *input,unsigned input_size,void *output,unsigned output_size,uint32_t checksum) {
    z_stream stream={0}; stream.next_in=(Bytef *)input; stream.avail_in=input_size; stream.next_out=output; stream.avail_out=output_size;
    if(inflateInit2(&stream,-MAX_WBITS) != Z_OK) return -1;
    int status=inflate(&stream,Z_FINISH);
    int valid=status==Z_STREAM_END && stream.total_out==output_size && stream.total_in==input_size && crc32(0,output,output_size)==checksum;
    inflateEnd(&stream); return valid ? 0 : -1;
}
struct NVLC { void *library, *instance, *player, *view; int hardware, rotation, volume, muted, input_failed; pthread_mutex_t error_lock; char failure[2048]; };
static void input_error(const void *event,void *opaque) {
    (void)event;
    NVLC *v=opaque;
    pthread_mutex_lock(&v->error_lock); v->input_failed=1; pthread_mutex_unlock(&v->error_lock);
}
// LibVLC 3 dialog callback ABI. Preserve the first specific decoder error;
// VLC follows it with a generic "Your input can't be opened" dialog.
typedef struct {
    void (*error)(void *,const char *,const char *);
    void (*login)(void *,void *,const char *,const char *,const char *,bool);
    void (*question)(void *,void *,const char *,const char *,int,const char *,const char *,const char *);
    void (*progress)(void *,void *,const char *,const char *,bool,float,const char *);
    void (*cancel)(void *,void *);
    void (*update)(void *,void *,float,const char *);
} DialogCallbacks;
static void display_error(void *opaque,const char *title,const char *message) {
    NVLC *v=opaque;
    pthread_mutex_lock(&v->error_lock);
    if(!v->failure[0]) snprintf(v->failure,sizeof(v->failure),"%s: %s",title ? title : "Playback error",message ? message : "");
    pthread_mutex_unlock(&v->error_lock);
}
static const DialogCallbacks dialogs={.error=display_error};
typedef struct Track { int id; char *name; struct Track *next; } Track;
static char error_text[1024];
#define FN(v, name, ret, ...) ((ret (*)(__VA_ARGS__))dlsym((v)->library, "libvlc_" name))
const char *nvlc_error(void) { return error_text; }
void nvlc_failure(NVLC *v,char *message,int capacity) {
    if(!message || capacity<=0) return;
    message[0]=0; if(!v) return;
    pthread_mutex_lock(&v->error_lock);
    snprintf(message,capacity,"%s",v->failure);
    pthread_mutex_unlock(&v->error_lock);
}
static int create_player(NVLC *v,int hardware,int rotation) {
    if(v->player) { nvlc_stop(v); FN(v,"media_player_release",void,void *)(v->player); v->player=NULL; }
    if(v->instance) { FN(v,"release",void,void *)(v->instance); v->instance=NULL; }
    char transform[64]; snprintf(transform,sizeof(transform),"--transform-type=%d",rotation);
    const char *args[] = {"--no-video-title-show", "--no-stats", "--no-osd", "--no-lua", "--no-metadata-network-access", getenv("NOIR_VLC_DEBUG") ? "--verbose=2" : "--quiet", "--vout=macosx", hardware ? "--avcodec-hw=any" : "--avcodec-hw=none",rotation ? "--video-filter=transform" : "--video-filter=",rotation ? transform : "--transform-type=90"};
    v->instance=FN(v,"new",void *,int,const char *const *)(10,args);
    if(v->instance) FN(v,"dialog_set_callbacks",void,void *,const DialogCallbacks *,void *)(v->instance,&dialogs,v);
    if(v->instance) v->player=FN(v,"media_player_new",void *,void *)(v->instance);
    if(!v->player) return -1;
    // LibVLC 3 reports INPUT_EVENT_DEAD as Ended even after an error. Latch
    // EncounteredError (0x10a) so a missed Playing poll is never an error heuristic.
    void *events=FN(v,"media_player_event_manager",void *,void *)(v->player);
    if(FN(v,"event_attach",int,void *,int,void (*)(const void *,void *),void *)(events,0x10a,input_error,v) != 0) return -1;
    FN(v,"media_player_set_nsobject",void,void *,void *)(v->player,v->view);
    FN(v,"audio_set_volume",int,void *,int)(v->player,v->volume);
    FN(v,"audio_set_mute",void,void *,int)(v->player,v->muted);
    v->hardware=hardware; v->rotation=rotation; return 0;
}
NVLC *nvlc_create(const char *path, void *view) {
    NVLC *v = calloc(1, sizeof(*v));
    if (!v) { snprintf(error_text, sizeof(error_text), "Out of memory"); return NULL; }
    v->volume=82;
    v->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!v->library) { snprintf(error_text, sizeof(error_text), "%s", dlerror()); free(v); return NULL; }
    const char *required[] = {"new", "release", "dialog_set_callbacks", "media_player_event_manager", "event_attach", "media_new_location", "media_release", "media_add_option", "media_player_new", "media_player_release", "media_player_set_media", "media_player_play", "media_player_stop", "media_player_set_nsobject", "media_player_get_state", "media_player_get_time", "media_player_get_length", "media_player_set_time", "media_player_set_pause", "audio_set_volume", "audio_set_mute", "media_player_set_rate", "video_set_aspect_ratio", "video_get_size", "audio_get_track", "video_get_spu", "media_player_get_chapter", "media_player_get_chapter_count", "media_player_set_chapter", "media_player_navigate", "audio_set_track", "video_set_spu", "media_player_add_slave", "video_take_snapshot", "audio_get_track_description", "video_get_spu_description", "track_description_list_release"};
    for (unsigned i = 0; i < sizeof(required)/sizeof(*required); i++) {
        char symbol[128]; snprintf(symbol, sizeof(symbol), "libvlc_%s", required[i]);
        if (!dlsym(v->library, symbol)) { snprintf(error_text, sizeof(error_text), "Missing %s", symbol); dlclose(v->library); free(v); return NULL; }
    }
    v->view=view;
    pthread_mutex_init(&v->error_lock,NULL);
    if (create_player(v,1,0)) { snprintf(error_text,sizeof(error_text),"Could not initialize VLC compatibility playback"); nvlc_destroy(v); return NULL; }
    return v;
}
void nvlc_stop(NVLC *v) {
    if(v && v->player) {
        FN(v,"media_player_stop",void,void *)(v->player);
        // Stop joins the input thread; detach its media as well so the player
        // cannot retain the disc input when the user asks macOS to eject it.
        FN(v,"media_player_set_media",void,void *,void *)(v->player,NULL);
    }
}
void nvlc_destroy(NVLC *v) {
    if (!v) return;
    if (v->player) { nvlc_stop(v); FN(v,"media_player_release",void,void *)(v->player); }
    if (v->instance) FN(v,"release",void,void *)(v->instance);
    pthread_mutex_destroy(&v->error_lock);
    // Cocoa plug-in classes remain registered; deliberately keep dlopen mapped.
    free(v);
}
int nvlc_open(NVLC *v,const char *source,int hardware,int rotation,int64_t start) {
    if(!v) return -1;
    // A failed earlier re-creation leaves no player; build one again rather than using NULL.
    if(!v->player || v->hardware != hardware || v->rotation != rotation) { if(create_player(v,hardware,rotation)) return -1; }
    nvlc_stop(v);
    pthread_mutex_lock(&v->error_lock); v->failure[0]=0; v->input_failed=0; pthread_mutex_unlock(&v->error_lock);
    void *m = FN(v,"media_new_location",void *,void *,const char *)(v->instance,source);
    if (!m) return -1;
    if (start > 0) { char option[96]; snprintf(option,sizeof(option),":start-time=%.3f",(double)start/1000.0); FN(v,"media_add_option",void,void *,const char *)(m,option); }
    FN(v,"media_add_option",void,void *,const char *)(m,hardware ? ":avcodec-hw=any" : ":avcodec-hw=none");
    FN(v,"media_player_set_media",void,void *,void *)(v->player,m);
    FN(v,"media_release",void,void *)(m);
    return FN(v,"media_player_play",int,void *)(v->player);
}
// Every entry point tolerates a missing player (failed create_player) instead of passing NULL to LibVLC.
#define PLAYER_OR(v, value) if(!(v) || !(v)->player) return value
void nvlc_pause(NVLC *v,int p) { PLAYER_OR(v,); FN(v,"media_player_set_pause",void,void *,int)(v->player,p); }
void nvlc_seek(NVLC *v,int64_t t) { PLAYER_OR(v,); FN(v,"media_player_set_time",void,void *,int64_t)(v->player,t); }
void nvlc_volume(NVLC *v,int a,int m) { if(!v) return; v->volume=a; v->muted=m; PLAYER_OR(v,); FN(v,"audio_set_volume",int,void *,int)(v->player,a); FN(v,"audio_set_mute",void,void *,int)(v->player,m); }
void nvlc_rate(NVLC *v,float r) { PLAYER_OR(v,); FN(v,"media_player_set_rate",int,void *,float)(v->player,r); }
void nvlc_aspect(NVLC *v,const char *a) { PLAYER_OR(v,); FN(v,"video_set_aspect_ratio",void,void *,const char *)(v->player,a); }
void nvlc_chapter(NVLC *v,int c) { PLAYER_OR(v,); FN(v,"media_player_set_chapter",void,void *,int)(v->player,c); }
void nvlc_navigate(NVLC *v,unsigned d) { PLAYER_OR(v,); FN(v,"media_player_navigate",void,void *,unsigned)(v->player,d); }
void nvlc_track(NVLC *v,int s,int i) { PLAYER_OR(v,); if(s) FN(v,"video_set_spu",int,void *,int)(v->player,i); else FN(v,"audio_set_track",int,void *,int)(v->player,i); }
int nvlc_subtitle(NVLC *v,const char *u) { PLAYER_OR(v,-1); return FN(v,"media_player_add_slave",int,void *,unsigned,const char *,int)(v->player,0,u,1); }
int nvlc_snapshot(NVLC *v,const char *p) { PLAYER_OR(v,-1); return FN(v,"video_take_snapshot",int,void *,unsigned,const char *,unsigned,unsigned)(v->player,0,p,0,0); }
NVLCState nvlc_state(NVLC *v) {
    NVLCState s = {0}; if(!v || !v->player) return s;
    s.state=FN(v,"media_player_get_state",int,void *)(v->player);
    pthread_mutex_lock(&v->error_lock); s.failed=v->input_failed; pthread_mutex_unlock(&v->error_lock);
    s.time=FN(v,"media_player_get_time",int64_t,void *)(v->player);
    s.length=FN(v,"media_player_get_length",int64_t,void *)(v->player);
    FN(v,"video_get_size",int,void *,unsigned,unsigned *,unsigned *)(v->player,0,&s.width,&s.height);
    s.audio=FN(v,"audio_get_track",int,void *)(v->player); s.subtitle=FN(v,"video_get_spu",int,void *)(v->player);
    s.chapter=FN(v,"media_player_get_chapter",int,void *)(v->player); s.chapters=FN(v,"media_player_get_chapter_count",int,void *)(v->player);
    return s;
}
int nvlc_tracks(NVLC *v,int subtitle,int *ids,char *names,int capacity,int stride) {
    PLAYER_OR(v,0);
    Track *head=subtitle ? FN(v,"video_get_spu_description",Track *,void *)(v->player) : FN(v,"audio_get_track_description",Track *,void *)(v->player);
    int n=0; for(Track *t=head;t && n<capacity;t=t->next,n++) { ids[n]=t->id; snprintf(names+n*stride,stride,"%s",t->name ? t->name : "Track"); }
    FN(v,"track_description_list_release",void,Track *)(head); return n;
}
