(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

type t = { 
  headers: Header.t;
  meth: Code.meth;
  uri: Uri.t;
  version: Code.version;
  encoding: Transfer.encoding;
}

let headers r = r.headers
let meth r = r.meth
let uri r = r.uri
let version r = r.version
let encoding r = r.encoding

let make ?(meth=`GET) ?(version=`HTTP_1_1) ?encoding ?headers uri =
  let headers = 
    match headers with
    | None -> Header.init ()
    | Some h -> h in
  let encoding =
    match encoding with
    | None -> begin
       (* Check for a content-length in the supplied headers first *)
       match Header.get_content_range headers with
       | Some clen -> Transfer.Fixed clen
       | None -> Transfer.Fixed 0 
     end
    | Some e -> e
  in
  { meth; version; headers; uri; encoding }

(* Make a client request, which involves guessing encoding and
   adding content headers if appropriate.
   @param chunked Forces chunked encoding
 *)
let make_for_client ?headers ?(chunked=true) ?(body_length=0) meth uri =
  let encoding =
    match chunked with
    | true -> Transfer.Chunked
    | false -> Transfer.Fixed body_length
  in
  make ~meth ~encoding ?headers uri

module type T = sig
  val headers : t -> Header.t
  val meth : t -> Code.meth
  (** Retrieve full HTTP request uri *)
  val uri : t -> Uri.t

  (** Retrieve HTTP version, usually 1.1 *)
  val version : t -> Code.version

  (** Retrieve the transfer encoding of this HTTP request *)
  val encoding : t -> Transfer.encoding

  (** TODO *)
  val params : t -> (string * string list) list

  (** TODO *)
  val get_param : t -> string -> string option

  val make : ?meth:Code.meth -> ?version:Code.version -> 
    ?encoding:Transfer.encoding -> ?headers:Header.t ->
    Uri.t -> t

  val make_for_client:
    ?headers:Header.t ->
    ?chunked:bool ->
    ?body_length:int ->
    Code.meth -> Uri.t -> t
end


module type S = sig
  module IO : IO.S

  val read : IO.ic -> t option IO.t
  val has_body : t -> bool
  val read_body_chunk :
    t -> IO.ic -> Transfer.chunk IO.t

  val write_header : t -> IO.oc -> unit IO.t
  val write_body : t -> IO.oc -> string -> unit IO.t
  val write_footer : t -> IO.oc -> unit IO.t
  val write : (t -> IO.oc -> unit IO.t) -> t -> IO.oc -> unit IO.t

  val is_form: t -> bool
  val read_form : t -> IO.ic -> (string * string list) list IO.t
end

module Make(IO : IO.S) = struct
  module IO = IO
  module Header_IO = Header_io.Make(IO)
  module Transfer_IO = Transfer_io.Make(IO)
  
  open IO

  let url_decode url = Uri.pct_decode url

  let pieces_sep = Re_str.regexp_string " "
  let parse_request_fst_line ic =
    let open Code in
    read_line ic >>= function
    |Some request_line -> begin
      match Re_str.split_delim pieces_sep request_line with
      | [ meth_raw; uri_raw; http_ver_raw ] -> begin
          match method_of_string meth_raw, version_of_string http_ver_raw with
          |Some m, Some v -> return (Some (m, (Uri.of_string uri_raw), v))
          |_ -> return None
      end
      | _ -> return None
    end
    |None -> return None

  let read ic =
    parse_request_fst_line ic >>= function
    |None -> return None
    |Some (meth, uri, version) ->
      Header_IO.parse ic >>= fun headers -> 
      let encoding = Header.get_transfer_encoding headers in
      return (Some { headers; meth; uri; version; encoding })

  let has_body req = Transfer.has_body req.encoding
  let read_body_chunk req ic = Transfer_IO.read req.encoding ic

  let host_of_uri uri = 
    match Uri.host uri with
    |None -> "localhost"
    |Some h -> h

  let write_header req oc =
   let fst_line = Printf.sprintf "%s %s %s\r\n" (Code.string_of_method req.meth)
      (Uri.path_and_query req.uri) (Code.string_of_version req.version) in
    let headers = Header.add req.headers "host" (host_of_uri req.uri) in
    let headers = Header.add_transfer_encoding headers req.encoding in
    IO.write oc fst_line >>= fun _ ->
    iter (IO.write oc) (Header.to_lines headers) >>= fun _ ->
    IO.write oc "\r\n"

  let write_body req oc buf =
    Transfer_IO.write req.encoding oc buf

  let write_footer req oc =
    match req.encoding with
    |Transfer.Chunked ->
       (* TODO Trailer header support *)
       IO.write oc "0\r\n\r\n"
    |Transfer.Fixed _ | Transfer.Unknown -> return ()

  (* TODO: remove either write' or write *)
  let write write_body req oc =
    write_header req oc >>= fun () ->
    write_body req oc >>= fun () ->
    write_footer req oc

  let is_form req = Header.is_form req.headers
  let read_form req ic = Header_IO.parse_form req.headers ic
end


