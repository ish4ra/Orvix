import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'secure_storage_factory.dart';

class RealDebridException implements Exception { const RealDebridException(this.message); final String message; @override String toString()=>message; }

class RealDebridService {
  RealDebridService._(); static final instance=RealDebridService._();
  static const _base='https://api.real-debrid.com/rest/1.0', _tokenKey='orvix_real_debrid_token_v1';
  final http.Client _client=http.Client(); final FlutterSecureStorage _storage=createOrvixSecureStorage();
  Future<String?> _token() async { final v=(await _storage.read(key:_tokenKey))?.trim(); return v==null||v.isEmpty?null:v; }
  Future<bool> get isConnected async => (await _token())!=null;
  Future<void> connectWithToken(String raw) async { final t=raw.trim(); if(t.isEmpty) throw const RealDebridException('Enter your Real-Debrid API token.'); _json(await _client.get(Uri.parse('$_base/user'),headers:_headers(t)).timeout(const Duration(seconds:20))); await _storage.write(key:_tokenKey,value:t); }
  Future<Map<String,dynamic>> account() async { final t=await _require(); final d=_json(await _client.get(Uri.parse('$_base/user'),headers:_headers(t)).timeout(const Duration(seconds:20))); return d is Map?Map<String,dynamic>.from(d):<String,dynamic>{}; }
  Future<String> resolveMagnet(String magnet,{int? fileIndex,String? fileNameHint}) async {
    final t=await _require();
    final added=_json(await _client.post(Uri.parse('$_base/torrents/addMagnet'),headers:_formHeaders(t),body:{'magnet':_stripMetadata(magnet)}).timeout(const Duration(seconds:30)));
    final id=added is Map?added['id']?.toString():null; if(id==null||id.isEmpty) throw const RealDebridException('Real-Debrid did not return a torrent id.');
    var info=await _info(t,id); final raw=info['files']; final files=raw is List?raw.whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList():<Map<String,dynamic>>[];
    final selected=_choose(files,fileIndex,fileNameHint); if(selected==null) throw const RealDebridException('No playable video file found in this Real-Debrid torrent.');
    final sid=selected['id']?.toString(); if(sid==null) throw const RealDebridException('Real-Debrid returned an invalid file id.');
    final sr=await _client.post(Uri.parse('$_base/torrents/selectFiles/$id'),headers:_formHeaders(t),body:{'files':sid}).timeout(const Duration(seconds:20)); if(![200,202,204].contains(sr.statusCode)) _json(sr);
    for(var n=0;n<24;n++){ info=await _info(t,id); final rawLinks=info['links']; final links=rawLinks is List?rawLinks.map((e)=>e.toString()).where((e)=>e.isNotEmpty).toList():<String>[];
      if(links.isNotEmpty){ final d=_json(await _client.post(Uri.parse('$_base/unrestrict/link'),headers:_formHeaders(t),body:{'link':links.first}).timeout(const Duration(seconds:25))); final u=d is Map?(d['download']??d['link'])?.toString():null; if(u!=null&&u.isNotEmpty)return u; }
      final s=info['status']?.toString().toLowerCase()??''; if(s.contains('error')||s.contains('virus')||s.contains('dead'))throw RealDebridException('Real-Debrid torrent failed: '+s); await Future<void>.delayed(const Duration(seconds:2)); }
    throw const RealDebridException('Real-Debrid is still preparing this torrent. Try again shortly.');
  }
  Future<Map<String,dynamic>> _info(String t,String id) async {final d=_json(await _client.get(Uri.parse('$_base/torrents/info/$id'),headers:_headers(t)).timeout(const Duration(seconds:20)));return d is Map?Map<String,dynamic>.from(d):<String,dynamic>{};}
  Map<String,dynamic>? _choose(List<Map<String,dynamic>> fs,int? idx,String? hint){final v=fs.where((f)=>_video((f['path']??'').toString())).toList();if(v.isEmpty)return null;final h=hint?.trim().toLowerCase();if(h!=null&&h.isNotEmpty){for(final f in v){if((f['path']??'').toString().toLowerCase().contains(h))return f;}}if(idx!=null&&idx>=0&&idx<fs.length&&_video((fs[idx]['path']??'').toString()))return fs[idx];v.sort((a,b)=>(int.tryParse(b['bytes']?.toString()??'')??0).compareTo(int.tryParse(a['bytes']?.toString()??'')??0));return v.first;}
  bool _video(String p)=>const ['.mkv','.mp4','.m4v','.avi','.mov','.webm','.ts','.m2ts'].any(p.toLowerCase().endsWith);
  Map<String,String> _headers(String t)=>{'Authorization':'Bearer $t','Accept':'application/json'}; Map<String,String> _formHeaders(String t)=>{..._headers(t),'Content-Type':'application/x-www-form-urlencoded'};
  dynamic _json(http.Response r){dynamic d;try{d=jsonDecode(r.body);}catch(_){d=null;}if(r.statusCode<200||r.statusCode>=300){final m=d is Map?d['error']?.toString():null;throw RealDebridException(m??'Real-Debrid request failed ('+r.statusCode.toString()+').');}return d;}
  Future<String> _require() async {final t=await _token();if(t==null)throw const RealDebridException('Connect Real-Debrid first.');return t;} String _stripMetadata(String v){final i=v.indexOf('&orvix_');return i<0?v:v.substring(0,i);}
  Future<void> logout()=>_storage.delete(key:_tokenKey); void dispose()=>_client.close();
}