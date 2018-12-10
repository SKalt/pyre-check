(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Pyre

open Ast
open Statement


let return_annotation ~define:({ Define.return_annotation; async; _ } as define) ~resolution =
  let annotation =
    Option.value_map
      return_annotation
      ~f:(Resolution.parse_annotation resolution)
      ~default:Type.Top
  in
  if async then
    Type.awaitable annotation
  else if Define.is_coroutine define then
    begin
      match annotation with
      | Type.Parametric { name; parameters = [_; _; return_annotation] }
        when Identifier.show name = "typing.Generator" ->
          Type.awaitable return_annotation
      | _ ->
          Type.Top
    end
  else
    annotation


let apply_decorators ~define ~resolution =
  let return_annotation = return_annotation ~define ~resolution in
  if Define.has_decorator define "contextlib.contextmanager" then
    let joined =
      try
        Resolution.join resolution return_annotation (Type.iterator Type.Bottom)
      with
        TypeOrder.Untracked _ ->
          (* Apply_decorators gets called when building the environment,
             which is unsound and can raise. *)
          Type.Object
    in
    if Type.is_iterator joined then
      {
        define with
        Define.return_annotation =
          Type.parametric "contextlib.GeneratorContextManager" [Type.single_parameter joined]
          |> Type.expression
          |> Option.some
      }
    else
      define
  else
    define


let create defines ~resolution =
  let ({ Define.name; _ } as define) = List.hd_exn defines in
  let open Type.Callable in
  let parameter { Node.value = { Ast.Parameter.name; annotation; value }; _ } =
    let name = Identifier.show name in
    let access =
      String.lstrip ~drop:(function | '*' -> true | _ -> false) name
      |> Access.create
    in
    let annotation =
      annotation
      >>| Resolution.parse_annotation resolution
      |> Option.value ~default:Type.Top
    in
    if String.is_prefix ~prefix:"**" name then
      Parameter.Keywords { Parameter.name = access; annotation; default = false }
    else if String.is_prefix ~prefix:"*" name then
      Parameter.Variable { Parameter.name = access; annotation; default = false }
    else
      Parameter.Named { Parameter.name = access; annotation; default = Option.is_some value }
  in
  let implicit =
    if Define.is_class_method define then
      Type.Callable.Class
    else if Define.is_method define && not (Define.is_static_method define) then
      Type.Callable.Instance
    else
      Type.Callable.Function
  in
  let implementation, overloads =
    let to_signature (implementation, overloads) ({ Define.parameters; _ } as define) =
      let signature =
        {
          annotation = return_annotation ~define ~resolution;
          parameters = Defined (List.map parameters ~f:parameter);
        }
      in
      if Define.is_overloaded_method define then
        implementation, signature :: overloads
      else
        signature, overloads
    in
    List.fold
      ~init:({ annotation = Type.Top; parameters = Type.Callable.Undefined }, [])
      ~f:to_signature
      defines
  in
  {
    kind = Named name;
    implementation;
    overloads;
    implicit;
  }
