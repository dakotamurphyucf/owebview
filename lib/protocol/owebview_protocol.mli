module Json : sig
  type t = Yojson.Safe.t

  val null : t
  val to_string : t -> string
  val of_string : string -> (t, string) result
  val member : string -> t -> (t, string) result
  val string_member : string -> t -> (string, string) result
end

module Codec : sig
  type 'a t

  val make :
    encode:('a -> Json.t) -> decode:(Json.t -> ('a, string) result) -> 'a t

  val encode : 'a t -> 'a -> Json.t
  val decode : 'a t -> Json.t -> ('a, string) result
  val xmap : ('a -> 'b) -> ('b -> 'a) -> 'a t -> 'b t
  val json : Json.t t
  val string : string t
  val bool : bool t
  val int : int t
  val float : float t
  val int64_string : int64 t
  val unit : unit t
  val option : 'a t -> 'a option t
  val list : 'a t -> 'a list t
end

module Rpc_error : sig
  type t = { code : string; message : string; data : Json.t option }

  val make : ?data:Json.t -> code:string -> string -> t
  val codec : t Codec.t
end

module Endpoint : sig
  type ('request, 'response) t

  val make :
    name:string ->
    request:'request Codec.t ->
    response:'response Codec.t ->
    ('request, 'response) t

  val name : ('request, 'response) t -> string
  val request : ('request, 'response) t -> 'request Codec.t
  val response : ('request, 'response) t -> 'response Codec.t
end

module Frontend_endpoint : module type of Endpoint

module Event : sig
  type 'event t

  val make : name:string -> event:'event Codec.t -> 'event t
  val name : 'event t -> string
  val event : 'event t -> 'event Codec.t
end

module Stream_endpoint : sig
  type ('request, 'event, 'command, 'result) t

  val make :
    name:string ->
    request:'request Codec.t ->
    event:'event Codec.t ->
    command:'command Codec.t ->
    result:'result Codec.t ->
    ('request, 'event, 'command, 'result) t

  val name : ('request, 'event, 'command, 'result) t -> string
  val request : ('request, 'event, 'command, 'result) t -> 'request Codec.t
  val event : ('request, 'event, 'command, 'result) t -> 'event Codec.t
  val command : ('request, 'event, 'command, 'result) t -> 'command Codec.t
  val result : ('request, 'event, 'command, 'result) t -> 'result Codec.t
end

module Envelope : sig
  type t = {
    version : int;
    kind : string;
    id : string option;
    payload : Json.t;
  }

  val current_version : int
  val make : ?id:string -> kind:string -> Json.t -> t
  val to_string : t -> string
  val of_string : string -> (t, string) result
end

module Sequenced : sig
  type 'event t = { sequence : int64; timestamp : float; event : 'event }

  val codec : 'event Codec.t -> 'event t Codec.t
end
