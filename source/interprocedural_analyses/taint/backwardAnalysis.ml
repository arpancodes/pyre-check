(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Analysis
open Ast
open Expression
open Pyre
open Domains
open AccessPath
module CallGraph = Interprocedural.CallGraph

module type FUNCTION_CONTEXT = sig
  val qualifier : Reference.t

  val definition : Statement.Define.t Node.t

  val debug : bool

  val profiler : TaintProfiler.t

  val environment : TypeEnvironment.ReadOnly.t

  val call_graph_of_define : CallGraph.DefineCallGraph.t

  val triggered_sinks : ForwardAnalysis.triggered_sinks
end

module State (FunctionContext : FUNCTION_CONTEXT) = struct
  type t = { taint: BackwardState.t }

  let bottom = { taint = BackwardState.bottom }

  let pp formatter { taint } = BackwardState.pp formatter taint

  let show = Format.asprintf "%a" pp

  let create () = { taint = BackwardState.empty }

  let less_or_equal ~left:{ taint = left; _ } ~right:{ taint = right; _ } =
    BackwardState.less_or_equal ~left ~right


  let join { taint = left } { taint = right; _ } =
    let taint = BackwardState.join left right in
    { taint }


  let widen ~previous:{ taint = prev; _ } ~next:{ taint = next; _ } ~iteration =
    let taint = BackwardState.widen ~iteration ~prev ~next in
    { taint }


  let profiler = FunctionContext.profiler

  let log format =
    if FunctionContext.debug then
      Log.dump format
    else
      Log.log ~section:`Taint format


  let get_callees ~location ~call =
    let callees =
      match
        CallGraph.DefineCallGraph.resolve_call FunctionContext.call_graph_of_define ~location ~call
      with
      | Some callees -> callees
      | None ->
          (* TODO(T105570363): This should be a fatal error. *)
          Log.warning
            "Could not find callees for `%a` at `%a` in the call graph."
            Expression.pp
            (Node.create_with_default_location (Expression.Call call))
            Location.pp
            location;
          CallGraph.RawCallees.create_unresolved Type.Any
    in
    log
      "Resolved callees for call `%a` at %a:@,%a"
      Expression.pp
      (Node.create_with_default_location (Expression.Call call))
      Location.pp
      location
      CallGraph.RawCallees.pp
      callees;
    callees


  let get_property_callees ~location ~attribute =
    let callees =
      CallGraph.DefineCallGraph.resolve_property_call
        FunctionContext.call_graph_of_define
        ~location
        ~attribute
    in
    let () =
      match callees with
      | Some callees ->
          log
            "Resolved property callees for `%s` at %a:@,%a"
            attribute
            Location.pp
            location
            CallGraph.RawCallees.pp
            callees
      | _ -> ()
    in
    callees


  let global_resolution = TypeEnvironment.ReadOnly.global_resolution FunctionContext.environment

  let local_annotations =
    TypeEnvironment.ReadOnly.get_local_annotations
      FunctionContext.environment
      (Node.value FunctionContext.definition |> Statement.Define.name)


  let is_constructor () =
    let { Node.value = { Statement.Define.signature = { name; _ }; _ }; _ } =
      FunctionContext.definition
    in
    match Reference.last name with
    | "__init__" -> true
    | _ -> false


  let first_parameter () =
    let { Node.value = { Statement.Define.signature = { parameters; _ }; _ }; _ } =
      FunctionContext.definition
    in
    match parameters with
    | { Node.value = { Parameter.name; _ }; _ } :: _ -> Some (Root.Variable name)
    | _ -> None


  let add_first_index index indices =
    if Features.FirstIndexSet.is_bottom indices then
      Features.to_first_name index
      >>| Features.FirstIndexInterned.intern
      >>| Features.FirstIndexSet.singleton
      |> Option.value ~default:Features.FirstIndexSet.bottom
    else
      indices


  (* This is where we can observe access paths reaching into LocalReturn and record the extraneous
     paths for more precise tito. *)
  let initial_taint =
    (* We handle constructors and property setters specially and track effects. *)
    if
      is_constructor ()
      || Statement.Define.is_property_setter (Node.value FunctionContext.definition)
    then
      match first_parameter () with
      | Some root ->
          BackwardState.assign
            ~root
            ~path:[]
            (BackwardState.Tree.create_leaf Domains.local_return_taint)
            BackwardState.empty
      | _ -> BackwardState.empty
    else
      BackwardState.assign
        ~root:Root.LocalResult
        ~path:[]
        (BackwardState.Tree.create_leaf Domains.local_return_taint)
        BackwardState.empty


  let transform_non_leaves path taint =
    let f prefix = prefix @ path in
    match path with
    | Abstract.TreeDomain.Label.AnyIndex :: _ -> taint
    | _ -> BackwardTaint.transform Features.ReturnAccessPathSet.Element Map ~f taint


  let read_tree = BackwardState.Tree.read ~transform_non_leaves

  let get_taint access_path { taint; _ } =
    match access_path with
    | None -> BackwardState.Tree.empty
    | Some { root; path } -> BackwardState.read ~transform_non_leaves ~root ~path taint


  let store_weak_taint ~root ~path taint { taint = state_taint } =
    { taint = BackwardState.assign ~weak:true ~root ~path taint state_taint }


  let analyze_definition ~define:_ state = state

  type call_target_result = {
    arguments_taint: BackwardState.Tree.t list;
    self_taint: BackwardState.Tree.t option;
    callee_taint: BackwardState.Tree.t option;
    state: t;
  }

  let join_call_target_results
      {
        arguments_taint = left_arguments_taint;
        self_taint = left_self_taint;
        callee_taint = left_callee_taint;
        state = left_state;
      }
      {
        arguments_taint = right_arguments_taint;
        self_taint = right_self_taint;
        callee_taint = right_callee_taint;
        state = right_state;
      }
    =
    let arguments_taint =
      List.map2_exn left_arguments_taint right_arguments_taint ~f:BackwardState.Tree.join
    in
    let join_option left right =
      match left, right with
      | Some left, Some right -> Some (BackwardState.Tree.join left right)
      | Some left, None -> Some left
      | None, Some right -> Some right
      | None, None -> None
    in
    let self_taint = join_option left_self_taint right_self_taint in
    let callee_taint = join_option left_callee_taint right_callee_taint in
    let state = join left_state right_state in
    { arguments_taint; self_taint; callee_taint; state }


  let apply_call_target
      ~resolution
      ~call_location
      ~self
      ~arguments
      ~return_type_breadcrumbs
      ~state:initial_state
      ~call_taint
      { CallGraph.CallTarget.target = call_target; implicit_self; collapse_tito = _ }
    =
    let arguments =
      if implicit_self then
        { Call.Argument.name = None; value = Option.value_exn self } :: arguments
      else
        arguments
    in
    let triggered_taint =
      match Hashtbl.find FunctionContext.triggered_sinks call_location with
      | Some items ->
          List.fold
            items
            ~f:(fun state (root, sink) ->
              let new_taint = BackwardState.Tree.create_leaf (BackwardTaint.singleton sink) in
              BackwardState.assign ~root ~path:[] new_taint state)
            ~init:BackwardState.bottom
      | None -> BackwardState.bottom
    in
    let taint_model =
      TaintProfiler.track_model_fetch
        ~profiler
        ~analysis:TaintProfiler.Backward
        ~call_target
        ~f:(fun () -> Model.get_callsite_model ~resolution ~call_target ~arguments)
    in
    log
      "Backward analysis of call to `%a` with arguments (%a)@,Call site model:@,%a"
      Interprocedural.Target.pretty_print
      call_target
      Ast.Expression.pp_expression_argument_list
      arguments
      Model.pp
      taint_model;
    let { TaintResult.backward; sanitizers; modes; _ } = taint_model.model in
    let sink_taint = BackwardState.join backward.sink_taint triggered_taint in
    let sink_argument_matches =
      BackwardState.roots sink_taint
      |> AccessPath.match_actuals_to_formals arguments
      |> List.map ~f:(fun (argument, argument_match) ->
             argument.Call.Argument.value, argument_match)
    in
    let tito_argument_matches =
      BackwardState.roots backward.taint_in_taint_out
      |> AccessPath.match_actuals_to_formals arguments
      |> List.map ~f:(fun (argument, argument_match) ->
             argument.Call.Argument.value, argument_match)
    in
    let sanitize_argument_matches =
      SanitizeRootMap.roots sanitizers.roots
      |> AccessPath.match_actuals_to_formals arguments
      |> List.map ~f:(fun (argument, argument_match) ->
             argument.Call.Argument.value, argument_match)
    in
    let combined_matches =
      List.zip_exn tito_argument_matches sanitize_argument_matches
      |> List.zip_exn sink_argument_matches
    in
    let combine_sink_taint location taint_tree { root; actual_path; formal_path } =
      BackwardState.read ~transform_non_leaves ~root ~path:[] sink_taint
      |> BackwardState.Tree.apply_call location ~callees:[call_target] ~port:root
      |> read_tree formal_path
      |> BackwardState.Tree.prepend actual_path
      |> BackwardState.Tree.join taint_tree
    in
    let get_argument_taint ~resolution ~argument:{ Call.Argument.value = argument; _ } =
      let global_sink =
        Model.get_global_model
          ~resolution
          ~location:
            (Location.with_module ~qualifier:FunctionContext.qualifier (Node.location argument))
          ~expression:argument
        |> Model.GlobalModel.get_sink
      in
      let access_path = of_expression ~resolution argument in
      get_taint access_path initial_state |> BackwardState.Tree.join global_sink
    in
    let combine_tito location taint_tree { AccessPath.root; actual_path; formal_path } =
      let translate_tito (tito_path, element) argument_taint =
        let compute_parameter_tito ~key:kind ~data:element argument_taint =
          let extra_paths =
            match Sinks.discard_transforms kind with
            | Sinks.LocalReturn ->
                BackwardTaint.fold
                  Features.ReturnAccessPathSet.Element
                  element
                  ~f:List.cons
                  ~init:[]
            | _ ->
                (* No special path handling for side effect taint *)
                [[]]
          in
          let breadcrumbs = BackwardTaint.breadcrumbs element in
          let tito_depth =
            BackwardTaint.fold TraceLength.Self element ~f:TraceLength.join ~init:TraceLength.bottom
          in
          let taint_to_propagate =
            match Sinks.discard_transforms kind with
            | Sinks.LocalReturn -> call_taint
            (* Attach nodes shouldn't affect analysis. *)
            | Sinks.Attach -> BackwardState.Tree.empty
            | Sinks.ParameterUpdate n -> (
                match List.nth arguments n with
                | None -> BackwardState.Tree.empty
                | Some argument -> get_argument_taint ~resolution ~argument)
            | _ -> failwith "unexpected tito sink"
          in
          let taint_to_propagate =
            match kind with
            | Sinks.Transform { sanitize_local; sanitize_global; _ } ->
                (* Apply source- and sink-specific tito sanitizers. *)
                let transforms = SanitizeTransform.Set.union sanitize_local sanitize_global in
                let sanitized_tito_sinks =
                  Sinks.extract_sanitized_sinks_from_transforms transforms
                in
                let sanitized_tito_sources = SanitizeTransform.Set.filter_sources transforms in
                let sanitized_tito_sinks_transforms =
                  SanitizeTransform.Set.filter_sinks transforms
                in
                taint_to_propagate
                |> BackwardState.Tree.sanitize sanitized_tito_sinks
                |> BackwardState.Tree.apply_sanitize_transforms sanitized_tito_sources
                |> BackwardState.Tree.apply_sanitize_sink_transforms sanitized_tito_sinks_transforms
                |> BackwardState.Tree.transform
                     BackwardTaint.kind
                     Filter
                     ~f:Flow.sink_can_match_rule
            | _ -> taint_to_propagate
          in
          let compute_tito_depth kind depth =
            match Sinks.discard_transforms kind with
            | Sinks.LocalReturn -> max depth (1 + tito_depth)
            | _ -> depth
          in
          List.fold
            extra_paths
            ~f:(fun taint extra_path ->
              read_tree extra_path taint_to_propagate
              |> BackwardState.Tree.collapse
                   ~transform:(BackwardTaint.add_breadcrumbs (Features.tito_broadening_set ()))
              |> BackwardTaint.add_breadcrumbs breadcrumbs
              |> BackwardTaint.transform
                   TraceLength.Self
                   (Context (BackwardTaint.kind, Map))
                   ~f:compute_tito_depth
              |> BackwardState.Tree.create_leaf
              |> BackwardState.Tree.prepend tito_path
              |> BackwardState.Tree.join taint)
            ~init:argument_taint
        in
        BackwardTaint.partition BackwardTaint.kind By ~f:Fn.id element
        |> Map.Poly.fold ~f:compute_parameter_tito ~init:argument_taint
      in
      let add_tito_feature_and_position leaf_taint =
        leaf_taint |> Frame.add_tito_position location |> Frame.add_breadcrumb (Features.tito ())
      in
      BackwardState.read ~transform_non_leaves ~root ~path:formal_path backward.taint_in_taint_out
      |> BackwardState.Tree.fold
           BackwardState.Tree.Path
           ~f:translate_tito
           ~init:BackwardState.Tree.bottom
      |> BackwardState.Tree.transform Frame.Self Map ~f:add_tito_feature_and_position
      |> BackwardState.Tree.prepend actual_path
      |> BackwardState.Tree.join taint_tree
    in
    let analyze_argument
        ~obscure_taint
        (arguments_taint, state)
        ((argument, sink_matches), ((_, tito_matches), (_, sanitize_matches)))
      =
      let location =
        Location.with_module ~qualifier:FunctionContext.qualifier argument.Node.location
      in
      let sink_taint =
        List.fold sink_matches ~f:(combine_sink_taint location) ~init:BackwardState.Tree.empty
      in
      let taint_in_taint_out =
        List.fold
          tito_matches
          ~f:(combine_tito argument.Node.location)
          ~init:BackwardState.Tree.empty
      in
      let taint_in_taint_out =
        if not (BackwardState.Tree.is_bottom obscure_taint) then
          let obscure_sanitize =
            List.map
              ~f:(fun { AccessPath.root; _ } -> SanitizeRootMap.get root sanitizers.roots)
              sanitize_matches
            |> List.fold ~f:Sanitize.join ~init:Sanitize.empty
            |> Sanitize.join sanitizers.global
            |> Sanitize.join sanitizers.parameters
          in
          (* Apply source- and sink- specific tito sanitizers for obscure models,
           * since the tito is not materialized in `backward.taint_in_taint_out`. *)
          let obscure_taint =
            match obscure_sanitize.tito with
            | Some AllTito -> BackwardState.Tree.bottom
            | Some (SpecificTito { sanitized_tito_sources; sanitized_tito_sinks }) ->
                let sanitized_tito_sources =
                  Sources.Set.to_sanitize_transforms_exn sanitized_tito_sources
                in
                let sanitized_tito_sinks_transforms =
                  Sinks.Set.to_sanitize_transforms_exn sanitized_tito_sinks
                in
                obscure_taint
                |> BackwardState.Tree.sanitize sanitized_tito_sinks
                |> BackwardState.Tree.apply_sanitize_transforms sanitized_tito_sources
                |> BackwardState.Tree.apply_sanitize_sink_transforms sanitized_tito_sinks_transforms
                |> BackwardState.Tree.transform
                     BackwardTaint.kind
                     Filter
                     ~f:Flow.sink_can_match_rule
            | None -> obscure_taint
          in
          let obscure_taint =
            BackwardState.Tree.transform
              Features.TitoPositionSet.Element
              Add
              ~f:argument.Node.location
              obscure_taint
          in
          BackwardState.Tree.join taint_in_taint_out obscure_taint
        else
          taint_in_taint_out
      in
      let taint = BackwardState.Tree.join sink_taint taint_in_taint_out in
      let state =
        match AccessPath.of_expression ~resolution argument with
        | Some { AccessPath.root; path } ->
            let breadcrumbs_to_add =
              BackwardState.Tree.filter_by_kind ~kind:Sinks.AddFeatureToArgument sink_taint
              |> BackwardTaint.breadcrumbs
            in
            if Features.BreadcrumbSet.is_bottom breadcrumbs_to_add then
              state
            else
              let taint =
                BackwardState.read state.taint ~root ~path
                |> BackwardState.Tree.add_breadcrumbs breadcrumbs_to_add
              in
              { taint = BackwardState.assign ~root ~path taint state.taint }
        | None -> state
      in
      taint :: arguments_taint, state
    in
    let obscure_taint =
      if TaintResult.ModeSet.contains Obscure modes then
        let breadcrumbs =
          Lazy.force return_type_breadcrumbs |> Features.BreadcrumbSet.add (Features.obscure ())
        in
        BackwardState.Tree.collapse
          ~transform:(BackwardTaint.add_breadcrumbs (Features.tito_broadening_set ()))
          call_taint
        |> BackwardTaint.add_breadcrumbs breadcrumbs
        |> BackwardState.Tree.create_leaf
      else
        BackwardState.Tree.bottom
    in
    let arguments_taint, state =
      List.rev combined_matches
      |> List.fold ~f:(analyze_argument ~obscure_taint) ~init:([], initial_state)
    in
    (* Extract the taint for self. *)
    let self_taint, arguments_taint =
      if implicit_self then
        match arguments_taint with
        | self_taint :: arguments_taint -> Some self_taint, arguments_taint
        | _ -> failwith "missing taint for self argument"
      else
        None, arguments_taint
    in
    { arguments_taint; self_taint; callee_taint = None; state }


  let apply_obscure_call ~callee ~arguments ~state:initial_state ~call_taint =
    log
      "Backward analysis of obscure call to `%a` with arguments (%a)"
      Expression.pp
      callee
      Ast.Expression.pp_expression_argument_list
      arguments;
    let obscure_taint =
      BackwardState.Tree.collapse
        ~transform:(BackwardTaint.add_breadcrumbs (Features.tito_broadening_set ()))
        call_taint
      |> BackwardTaint.add_breadcrumb (Features.obscure ())
      |> BackwardState.Tree.create_leaf
    in
    let compute_argument_taint { Call.Argument.value = argument; _ } =
      let taint = obscure_taint in
      let taint =
        match argument.Node.value with
        | Starred (Starred.Once _)
        | Starred (Starred.Twice _) ->
            BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex] taint
        | _ -> taint
      in
      let taint =
        BackwardState.Tree.transform
          Features.TitoPositionSet.Element
          Add
          ~f:argument.Node.location
          taint
      in
      taint
    in
    let arguments_taint = List.map ~f:compute_argument_taint arguments in
    { arguments_taint; self_taint = None; callee_taint = Some obscure_taint; state = initial_state }


  let apply_constructor_targets
      ~resolution
      ~call_location
      ~callee
      ~arguments
      ~new_targets
      ~init_targets
      ~return_type_breadcrumbs
      ~state:initial_state
      ~call_taint
    =
    (* Call `__init__`. Add the `self` implicit argument. *)
    let { arguments_taint = init_arguments_taint; self_taint; callee_taint = _; state } =
      match init_targets with
      | [] ->
          {
            arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
            self_taint = Some call_taint;
            callee_taint = None;
            state = initial_state;
          }
      | init_targets ->
          let call_expression =
            Expression.Call { Call.callee; arguments } |> Node.create ~location:call_location
          in
          List.map init_targets ~f:(fun target ->
              apply_call_target
                ~resolution
                ~call_location
                ~self:(Some call_expression)
                ~arguments
                ~return_type_breadcrumbs
                ~state:initial_state
                ~call_taint
                { CallGraph.CallTarget.target; implicit_self = true; collapse_tito = true })
          |> List.fold
               ~f:join_call_target_results
               ~init:
                 {
                   arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
                   self_taint = None;
                   callee_taint = None;
                   state = create ();
                 }
    in
    let self_taint = Option.value_exn self_taint in

    (* Call `__new__`. *)
    let call_target_result =
      match new_targets with
      | []
      | [`Method { Interprocedural.Target.class_name = "object"; method_name = "__new__" }] ->
          { arguments_taint = init_arguments_taint; self_taint = None; callee_taint = None; state }
      | new_targets ->
          (* Add the `cls` implicit argument. *)
          let {
            arguments_taint = new_arguments_taint;
            self_taint = callee_taint;
            callee_taint = _;
            state;
          }
            =
            List.map new_targets ~f:(fun target ->
                apply_call_target
                  ~resolution
                  ~call_location
                  ~self:(Some callee)
                  ~arguments
                  ~return_type_breadcrumbs
                  ~state
                  ~call_taint:self_taint
                  { CallGraph.CallTarget.target; implicit_self = true; collapse_tito = true })
            |> List.fold
                 ~f:join_call_target_results
                 ~init:
                   {
                     arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
                     self_taint = None;
                     callee_taint = None;
                     state = create ();
                   }
          in
          {
            arguments_taint =
              List.map2_exn init_arguments_taint new_arguments_taint ~f:BackwardState.Tree.join;
            self_taint = None;
            callee_taint;
            state;
          }
    in

    call_target_result


  let apply_callees_and_return_arguments_taint
      ~resolution
      ~callee
      ~call_location
      ~arguments
      ~state:initial_state
      ~call_taint
      {
        CallGraph.RawCallees.call_targets;
        new_targets;
        init_targets;
        return_type;
        higher_order_parameter = _;
        unresolved;
      }
    =
    let call_taint =
      (* Add index breadcrumb if appropriate. *)
      match callee.Node.value, arguments with
      | Expression.Name (Name.Attribute { attribute = "get"; _ }), index :: _ ->
          let label = get_index index.Call.Argument.value in
          BackwardState.Tree.transform
            Features.FirstIndexSet.Self
            Map
            ~f:(add_first_index label)
            call_taint
      | _ -> call_taint
    in

    let call_targets, unresolved, call_taint =
      (* Specially handle super.__init__ calls and explicit calls to superclass' `__init__` in
         constructors for tito. *)
      match Node.value callee with
      | Name (Name.Attribute { base; attribute; _ })
        when is_constructor ()
             && String.equal attribute "__init__"
             && Interprocedural.CallResolution.is_super
                  ~resolution
                  ~define:FunctionContext.definition
                  base ->
          (* If the super call is `object.__init__`, this is likely due to a lack of type
             information for that constructor - we treat that case as obscure to not lose argument
             taint for these calls. *)
          let call_targets, unresolved =
            match call_targets with
            | [
             {
               CallGraph.CallTarget.target =
                 `Method { class_name = "object"; method_name = "__init__" };
               _;
             };
            ] ->
                [], true
            | _ -> call_targets, unresolved
          in
          let call_taint =
            BackwardState.Tree.create_leaf Domains.local_return_taint
            |> BackwardState.Tree.join call_taint
          in
          call_targets, unresolved, call_taint
      | _ -> call_targets, unresolved, call_taint
    in

    let call_targets =
      (* Special handling for the missing-flow analysis. *)
      if unresolved && TaintConfiguration.is_missing_flow_analysis Type then (
        let callable =
          Model.unknown_callee
            ~location:(Location.with_module call_location ~qualifier:FunctionContext.qualifier)
            ~call:(Expression.Call { Call.callee; arguments })
        in
        if not (Interprocedural.FixpointState.has_model callable) then
          Model.register_unknown_callee_model callable;
        let target =
          { CallGraph.CallTarget.target = callable; implicit_self = false; collapse_tito = true }
        in
        target :: call_targets)
      else
        call_targets
    in

    (* Extract the implicit self, if any *)
    let self =
      match callee.Node.value with
      | Expression.Name (Name.Attribute { base; _ }) -> Some base
      | _ ->
          (* Default to a benign self if we don't understand/retain information of what self is. *)
          Expression.Constant Constant.NoneLiteral
          |> Node.create ~location:callee.Node.location
          |> Option.some
    in

    let return_type_breadcrumbs =
      lazy
        (let resolution = Resolution.global_resolution resolution in
         Features.type_breadcrumbs ~resolution (Some return_type))
    in

    (* Apply regular call targets. *)
    let call_target_result =
      List.map
        call_targets
        ~f:
          (apply_call_target
             ~resolution
             ~call_location
             ~self
             ~arguments
             ~return_type_breadcrumbs
             ~state:initial_state
             ~call_taint)
      |> List.fold
           ~f:join_call_target_results
           ~init:
             {
               arguments_taint = List.map arguments ~f:(fun _ -> BackwardState.Tree.bottom);
               self_taint = None;
               callee_taint = None;
               state = create ();
             }
    in

    (* Apply an obscure call if the call was not fully resolved. *)
    let call_target_result =
      if unresolved then
        apply_obscure_call ~callee ~arguments ~state:initial_state ~call_taint
        |> join_call_target_results call_target_result
      else
        call_target_result
    in

    (* Apply constructor calls, if any. *)
    let call_target_result =
      match new_targets, init_targets with
      | [], [] -> call_target_result
      | _ ->
          apply_constructor_targets
            ~resolution
            ~call_location
            ~callee
            ~arguments
            ~new_targets
            ~init_targets
            ~return_type_breadcrumbs
            ~state:initial_state
            ~call_taint
          |> join_call_target_results call_target_result
    in

    call_target_result


  let rec analyze_arguments ~resolution ~arguments ~arguments_taint ~state =
    (* Explicitly analyze arguments from right to left (opposite of forward analysis). *)
    List.zip_exn arguments arguments_taint
    |> List.rev
    |> List.fold
         ~init:state
         ~f:(fun state ({ Call.Argument.value = argument; _ }, argument_taint) ->
           analyze_unstarred_expression ~resolution argument_taint argument state)


  and analyze_callee ~resolution ~callee ~self_taint ~callee_taint ~state =
    match self_taint, callee_taint with
    | _, Some callee_taint -> (
        match callee.Node.value with
        | Expression.Name (Name.Attribute { base; attribute; special }) ->
            analyze_attribute_access
              ~resolution
              ~location:callee.Node.location
              ~resolve_properties:false (* We are already analyzing a call. *)
              ~base
              ~attribute
              ~special
              ~base_taint:(Option.value self_taint ~default:BackwardState.Tree.bottom)
              ~attribute_taint:callee_taint
              ~state
        | _ -> analyze_expression ~resolution ~taint:callee_taint ~state ~expression:callee)
    | Some self_taint, None -> (
        match callee.Node.value with
        | Expression.Name (Name.Attribute { base; _ }) ->
            analyze_expression ~resolution ~taint:self_taint ~state ~expression:base
        | _ -> state)
    | None, None -> state


  and analyze_attribute_access
      ~resolution
      ~location
      ~resolve_properties
      ~base
      ~attribute
      ~special
      ~base_taint
      ~attribute_taint
      ~state
    =
    let expression =
      Expression.Name (Name.Attribute { base; attribute; special }) |> Node.create ~location
    in
    let properties =
      if resolve_properties then get_property_callees ~location ~attribute else None
    in
    match properties with
    | Some { call_targets = _ :: _ as call_targets; return_type; _ } ->
        apply_callees
          ~resolution
          ~callee:expression
          ~call_location:location
          ~arguments:[]
          ~state
          ~call_taint:attribute_taint
          (CallGraph.RawCallees.create ~call_targets ~return_type ())
    | _ ->
        let location = Location.with_module ~qualifier:FunctionContext.qualifier location in
        let global_model = Model.get_global_model ~resolution ~expression ~location in
        let add_tito_features taint =
          let attribute_breadcrumbs =
            global_model |> Model.GlobalModel.get_tito |> BackwardState.Tree.breadcrumbs
          in
          BackwardState.Tree.add_breadcrumbs attribute_breadcrumbs taint
        in

        let apply_attribute_sanitizers taint =
          let sanitizer = Model.GlobalModel.get_sanitize global_model in
          let taint =
            match sanitizer.sinks with
            | Some AllSinks -> BackwardState.Tree.empty
            | Some (SpecificSinks sanitized_sinks) ->
                let sanitized_sinks_transforms =
                  Sinks.Set.to_sanitize_transforms_exn sanitized_sinks
                in
                taint
                |> BackwardState.Tree.sanitize sanitized_sinks
                |> BackwardState.Tree.apply_sanitize_sink_transforms sanitized_sinks_transforms
            | _ -> taint
          in
          let taint =
            match sanitizer.sources with
            | Some (SpecificSources sanitized_sources) ->
                let sanitized_sources_transforms =
                  Sources.Set.to_sanitize_transforms_exn sanitized_sources
                in
                taint
                |> BackwardState.Tree.apply_sanitize_transforms sanitized_sources_transforms
                |> BackwardState.Tree.transform
                     BackwardTaint.kind
                     Filter
                     ~f:Flow.sink_can_match_rule
            | _ -> taint
          in
          taint
        in

        let taint =
          attribute_taint
          |> add_tito_features
          |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.Index attribute]
          |> apply_attribute_sanitizers
          |> BackwardState.Tree.join base_taint
        in

        analyze_expression ~resolution ~taint ~state ~expression:base


  and analyze_arguments_for_lambda_call
      ~resolution
      ~arguments
      ~arguments_taint
      ~state
      ~lambda_argument:
        { Call.Argument.value = { location = lambda_location; _ } as lambda_callee; _ }
      { CallGraph.HigherOrderParameter.index = lambda_index; call_targets; return_type }
    =
    (* If we have a lambda `fn` getting passed into `hof`, we use the following strategy:
     * hof(q, fn, x, y) gets translated into (analyzed backwards)
     * if rand():
     *   $all = {q, x, y}
     *   $result = fn( *all, **all)
     * else:
     *   $result = fn
     * hof(q, $result, x, y)
     *)
    let result_taint = List.nth_exn arguments_taint lambda_index in
    let non_lambda_arguments_taint =
      let arguments_taint = List.zip_exn arguments arguments_taint in
      List.take arguments_taint lambda_index @ List.drop arguments_taint (lambda_index + 1)
    in

    (* Simulate if branch. *)
    let if_branch_state, all_taint =
      (* Simulate $result = fn( *all, **all) *)
      let all_argument =
        Expression.Name (Name.Identifier "$all") |> Node.create ~location:lambda_location
      in
      let arguments =
        [
          {
            Call.Argument.value =
              Expression.Starred (Starred.Once all_argument)
              |> Node.create ~location:lambda_location;
            name = None;
          };
          {
            Call.Argument.value =
              Expression.Starred (Starred.Twice all_argument)
              |> Node.create ~location:lambda_location;
            name = None;
          };
        ]
      in
      let { arguments_taint; self_taint; callee_taint; state } =
        apply_callees_and_return_arguments_taint
          ~resolution
          ~callee:lambda_callee
          ~call_location:lambda_location
          ~arguments
          ~call_taint:result_taint
          ~state
          (CallGraph.RawCallees.create ~call_targets ~return_type ())
      in
      let state =
        analyze_callee ~resolution ~callee:lambda_callee ~self_taint ~callee_taint ~state
      in
      let all_taint =
        arguments_taint
        |> List.fold ~f:BackwardState.Tree.join ~init:BackwardState.Tree.bottom
        |> read_tree [Abstract.TreeDomain.Label.AnyIndex]
        |> BackwardState.Tree.add_breadcrumb (Features.lambda ())
      in
      state, all_taint
    in

    (* Simulate else branch. *)
    let else_branch_state =
      analyze_expression ~resolution ~taint:result_taint ~state ~expression:lambda_callee
    in

    (* Join both branches. *)
    let state = join else_branch_state if_branch_state in

    (* Analyze arguments. *)
    List.fold
      non_lambda_arguments_taint
      ~init:state
      ~f:(fun state ({ Call.Argument.value = argument; _ }, argument_taint) ->
        let argument_taint = BackwardState.Tree.join argument_taint all_taint in
        analyze_unstarred_expression ~resolution argument_taint argument state)


  and apply_callees
      ~resolution
      ~callee
      ~call_location
      ~arguments
      ~state:initial_state
      ~call_taint
      raw_callees
    =
    let { arguments_taint; self_taint; callee_taint; state } =
      apply_callees_and_return_arguments_taint
        ~resolution
        ~callee
        ~call_location
        ~arguments
        ~state:initial_state
        ~call_taint
        raw_callees
    in

    let state =
      match raw_callees with
      | {
       higher_order_parameter =
         Some ({ CallGraph.HigherOrderParameter.index; _ } as higher_order_parameter);
       _;
      } -> (
          match List.nth arguments index with
          | Some lambda_argument ->
              analyze_arguments_for_lambda_call
                ~resolution
                ~arguments
                ~arguments_taint
                ~state
                ~lambda_argument
                higher_order_parameter
          | _ -> analyze_arguments ~resolution ~arguments ~arguments_taint ~state)
      | _ -> analyze_arguments ~resolution ~arguments ~arguments_taint ~state
    in
    let state = analyze_callee ~resolution ~callee ~self_taint ~callee_taint ~state in
    state


  and analyze_dictionary_entry ~resolution taint state { Dictionary.Entry.key; value } =
    let key_taint = read_tree [AccessPath.dictionary_keys] taint in
    let state = analyze_expression ~resolution ~taint:key_taint ~state ~expression:key in
    let field_name = AccessPath.get_index key in
    let value_taint = read_tree [field_name] taint in
    analyze_expression ~resolution ~taint:value_taint ~state ~expression:value


  and analyze_reverse_list_element ~total ~resolution taint reverse_position state expression =
    let position = total - reverse_position - 1 in
    let index_name = Abstract.TreeDomain.Label.Index (string_of_int position) in
    let value_taint = read_tree [index_name] taint in
    analyze_expression ~resolution ~taint:value_taint ~state ~expression


  and generator_resolution ~resolution generators =
    let resolve_generator resolution generator =
      Resolution.resolve_assignment resolution (Statement.Statement.generator_assignment generator)
    in
    List.fold generators ~init:resolution ~f:resolve_generator


  and analyze_generators ~resolution ~state generators =
    let handle_generator state ({ Comprehension.Generator.conditions; _ } as generator) =
      let state =
        List.fold conditions ~init:state ~f:(fun state condition ->
            analyze_expression
              ~resolution
              ~taint:BackwardState.Tree.empty
              ~state
              ~expression:condition)
      in
      let { Statement.Assign.target; value; _ } =
        Statement.Statement.generator_assignment generator
      in
      analyze_assignment ~resolution ~target ~value state
    in
    List.fold ~f:handle_generator generators ~init:state


  and analyze_comprehension ~resolution taint { Comprehension.element; generators; _ } state =
    let resolution = generator_resolution ~resolution generators in
    let element_taint = read_tree [Abstract.TreeDomain.Label.AnyIndex] taint in
    let state = analyze_expression ~resolution ~taint:element_taint ~state ~expression:element in
    analyze_generators ~resolution ~state generators


  (* Skip through * and **. Used at call sites where * and ** are handled explicitly *)
  and analyze_unstarred_expression ~resolution taint expression state =
    match expression.Node.value with
    | Starred (Starred.Once expression)
    | Starred (Starred.Twice expression) ->
        analyze_expression ~resolution ~taint ~state ~expression
    | _ -> analyze_expression ~resolution ~taint ~state ~expression


  and analyze_call ~resolution ~location ~taint ~state ~callee ~arguments =
    match { Call.callee; arguments } with
    | {
     callee =
       { Node.value = Name (Name.Attribute { base; attribute = "__setitem__"; _ }); _ } as callee;
     arguments = [{ Call.Argument.value = index; _ }; { Call.Argument.value; _ }] as arguments;
    } ->
        (* Ensure we simulate the body of __setitem__ in case the function contains taint. *)
        let state =
          let callees = get_callees ~location ~call:{ Call.callee; arguments } in
          if CallGraph.RawCallees.is_partially_resolved callees then
            apply_callees
              ~resolution
              ~call_location:location
              ~state
              ~callee
              ~arguments
              ~call_taint:taint
              callees
          else
            state
        in
        (* Handle base[index] = value. *)
        analyze_assignment
          ~resolution
          ~fields:[AccessPath.get_index index]
          ~target:base
          ~value
          state
    | {
     callee = { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
     arguments = [{ Call.Argument.value = argument_value; _ }];
    } ->
        let index = AccessPath.get_index argument_value in
        let taint =
          BackwardState.Tree.prepend [index] taint
          |> BackwardState.Tree.transform Features.FirstIndexSet.Self Map ~f:(add_first_index index)
        in

        analyze_expression ~resolution ~taint ~state ~expression:base
    (* Special case x.__iter__().__next__() as being a random index access (this pattern is the
       desugaring of `for element in x`). Special case dictionary keys appropriately. *)
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               {
                 base =
                   {
                     Node.value =
                       Call
                         {
                           callee =
                             {
                               Node.value =
                                 Name (Name.Attribute { base; attribute = "__iter__"; _ });
                               _;
                             };
                           arguments = [];
                         };
                     _;
                   };
                 attribute = "__next__";
                 _;
               });
         _;
       };
     arguments = [];
    } ->
        let label =
          (* For dictionaries, the default iterator is keys. *)
          if Resolution.resolve_expression_to_type resolution base |> Type.is_dictionary_or_mapping
          then
            AccessPath.dictionary_keys
          else
            Abstract.TreeDomain.Label.AnyIndex
        in

        let taint = BackwardState.Tree.prepend [label] taint in
        analyze_expression ~resolution ~taint ~state ~expression:base
    (* We special-case object.__setattr__, which is sometimes used in order to work around
       dataclasses being frozen post-initialization. *)
    | {
     callee =
       {
         Node.value =
           Name
             (Name.Attribute
               {
                 base = { Node.value = Name (Name.Identifier "object"); _ };
                 attribute = "__setattr__";
                 _;
               });
         location;
       };
     arguments =
       [
         { Call.Argument.value = self; name = None };
         {
           Call.Argument.value =
             {
               Node.value =
                 Expression.Constant (Constant.String { value = attribute; kind = String });
               _;
             };
           name = None;
         };
         { Call.Argument.value; name = None };
       ];
    } ->
        analyze_assignment
          ~resolution
          ~target:
            {
              Node.value = Name (Name.Attribute { base = self; attribute; special = true });
              location;
            }
          ~value
          state
    (* `getattr(a, "field", default)` should evaluate to the join of `a.field` and `default`. *)
    | {
     callee = { Node.value = Name (Name.Identifier "getattr"); location };
     arguments =
       [
         { Call.Argument.value = base; _ };
         {
           Call.Argument.value =
             {
               Node.value =
                 Expression.Constant (Constant.String { StringLiteral.value = attribute; _ });
               _;
             };
           _;
         };
         { Call.Argument.value = default; _ };
       ];
    } ->
        let attribute_expression =
          {
            Node.location;
            value = Expression.Name (Name.Attribute { base; attribute; special = false });
          }
        in
        let state = analyze_expression ~resolution ~state ~expression:attribute_expression ~taint in
        analyze_expression ~resolution ~state ~expression:default ~taint
    (* `zip(a, b, ...)` creates a taint object whose first index has a's taint, second index has b's
       taint, etc. *)
    | { callee = { Node.value = Name (Name.Identifier "zip"); _ }; arguments = lists } ->
        let taint = BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex] taint in
        let analyze_zipped_list index state { Call.Argument.value; _ } =
          let index_name = Abstract.TreeDomain.Label.Index (string_of_int index) in
          let taint =
            BackwardState.Tree.read [index_name] taint
            |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex]
          in
          analyze_expression ~resolution ~state ~taint ~expression:value
        in
        List.foldi lists ~init:state ~f:analyze_zipped_list
    (* dictionary .keys(), .values() and .items() functions are special, as they require handling of
       DictionaryKeys taint. *)
    | { callee = { Node.value = Name (Name.Attribute { base; attribute = "values"; _ }); _ }; _ }
      when Resolution.resolve_expression_to_type resolution base |> Type.is_dictionary_or_mapping ->
        let taint =
          taint
          |> BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex]
          |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex]
        in
        analyze_expression ~resolution ~taint ~state ~expression:base
    | { callee = { Node.value = Name (Name.Attribute { base; attribute = "keys"; _ }); _ }; _ }
      when Resolution.resolve_expression_to_type resolution base |> Type.is_dictionary_or_mapping ->
        let taint =
          taint
          |> BackwardState.Tree.read [AccessPath.dictionary_keys]
          |> BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex]
        in
        analyze_expression ~resolution ~taint ~state ~expression:base
    | { callee = { Node.value = Name (Name.Attribute { base; attribute = "items"; _ }); _ }; _ }
      when Resolution.resolve_expression_to_type resolution base |> Type.is_dictionary_or_mapping ->
        (* When we're faced with an assign of the form `k, v = d.items().__iter__().__next__()`, the
           taint we analyze d.items() under will be {* -> {0 -> k, 1 -> v} }. We want to analyze d
           itself under the taint of `{* -> v, $keys -> k}`. *)
        let item_taint = BackwardState.Tree.read [Abstract.TreeDomain.Label.AnyIndex] taint in
        let key_taint =
          BackwardState.Tree.read [Abstract.TreeDomain.Label.create_int_index 0] item_taint
        in
        let value_taint =
          BackwardState.Tree.read [Abstract.TreeDomain.Label.create_int_index 1] item_taint
        in
        let taint =
          BackwardState.Tree.join
            (BackwardState.Tree.prepend [AccessPath.dictionary_keys] key_taint)
            (BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex] value_taint)
        in
        analyze_expression ~resolution ~taint ~state ~expression:base
    | {
     Call.callee =
       {
         Node.value =
           Name
             (Name.Attribute
               { base = { Node.value = Expression.Name name; _ }; attribute = "gather"; _ });
         _;
       };
     arguments;
    }
      when String.equal "asyncio" (Name.last name) ->
        analyze_expression
          ~resolution
          ~taint
          ~state
          ~expression:
            {
              Node.location;
              value =
                Expression.Tuple
                  (List.map arguments ~f:(fun argument -> argument.Call.Argument.value));
            }
    | {
     Call.callee = { Node.value = Name (Name.Identifier "reveal_taint"); _ };
     arguments = [{ Call.Argument.value = expression; _ }];
    } ->
        begin
          match of_expression ~resolution expression with
          | None ->
              Log.dump
                "%a: Revealed backward taint for `%s`: expression is too complex"
                Location.WithModule.pp
                (Location.with_module location ~qualifier:FunctionContext.qualifier)
                (Transform.sanitize_expression expression |> Expression.show)
          | access_path ->
              let taint = get_taint access_path state in
              Log.dump
                "%a: Revealed backward taint for `%s`: %s"
                Location.WithModule.pp
                (Location.with_module location ~qualifier:FunctionContext.qualifier)
                (Transform.sanitize_expression expression |> Expression.show)
                (BackwardState.Tree.show taint)
        end;
        state
    | { Call.callee = { Node.value = Name (Name.Identifier "super"); _ }; arguments } -> (
        match arguments with
        | [_; Call.Argument.{ value = object_; _ }] ->
            analyze_expression ~resolution ~taint ~state ~expression:object_
        | _ -> (
            (* Use implicit self *)
            match first_parameter () with
            | Some root -> store_weak_taint ~root ~path:[] taint state
            | None -> state))
    | _ ->
        let taint =
          match Node.value callee with
          | Name
              (Name.Attribute
                {
                  base = { Node.value = Expression.Constant (Constant.String _); _ };
                  attribute = "format";
                  _;
                }) ->
              BackwardState.Tree.add_breadcrumb (Features.format_string ()) taint
          | _ -> taint
        in
        let { Call.callee; arguments } =
          CallGraph.redirect_special_calls ~resolution { Call.callee; arguments }
        in
        let callees = get_callees ~location ~call:{ Call.callee; arguments } in
        apply_callees
          ~resolution
          ~call_location:location
          ~state
          ~callee
          ~arguments
          ~call_taint:taint
          callees


  and analyze_joined_string ~resolution ~taint ~state ~location substrings =
    let taint =
      let literal_string_sinks = TaintConfiguration.literal_string_sinks () in
      if List.is_empty literal_string_sinks then
        taint
      else
        let value =
          List.map substrings ~f:(function
              | Substring.Format _ -> "{}"
              | Substring.Literal { Node.value; _ } -> value)
          |> String.concat ~sep:""
        in
        List.fold
          literal_string_sinks
          ~f:(fun taint { TaintConfiguration.sink_kind; pattern } ->
            if Re2.matches pattern value then
              BackwardState.Tree.join
                taint
                (BackwardState.Tree.create_leaf (BackwardTaint.singleton ~location sink_kind))
            else
              taint)
          ~init:taint
    in
    let taint = BackwardState.Tree.add_breadcrumb (Features.format_string ()) taint in
    List.fold
      substrings
      ~f:(fun state substring ->
        match substring with
        | Substring.Format expression -> analyze_expression ~resolution ~taint ~state ~expression
        | Substring.Literal _ -> state)
      ~init:state


  and analyze_expression ~resolution ~taint ~state ~expression:({ Node.location; _ } as expression) =
    log
      "Backward analysis of expression: `%a` with backward taint: %a"
      Expression.pp
      expression
      BackwardState.Tree.pp
      taint;
    match expression.Node.value with
    | Await expression -> analyze_expression ~resolution ~taint ~state ~expression
    | BooleanOperator { left; operator = _; right } ->
        analyze_expression ~resolution ~taint ~state ~expression:right
        |> fun state -> analyze_expression ~resolution ~taint ~state ~expression:left
    | ComparisonOperator ({ left; operator = _; right } as comparison) -> (
        match ComparisonOperator.override ~location comparison with
        | Some override -> analyze_expression ~resolution ~taint ~state ~expression:override
        | None ->
            let taint =
              BackwardState.Tree.add_breadcrumbs (Features.type_bool_scalar_set ()) taint
            in
            analyze_expression ~resolution ~taint ~state ~expression:right
            |> fun state -> analyze_expression ~resolution ~taint ~state ~expression:left)
    | Call { callee; arguments } ->
        analyze_call ~resolution ~location ~taint ~state ~callee ~arguments
    | Constant _ -> state
    | Dictionary { Dictionary.entries; keywords } ->
        let state = List.fold ~f:(analyze_dictionary_entry ~resolution taint) entries ~init:state in
        let analyze_dictionary_keywords state keywords =
          analyze_expression ~resolution ~taint ~state ~expression:keywords
        in
        List.fold keywords ~f:analyze_dictionary_keywords ~init:state
    | DictionaryComprehension
        { Comprehension.element = { Dictionary.Entry.key; value }; generators; _ } ->
        let resolution = generator_resolution ~resolution generators in
        let state =
          analyze_expression
            ~resolution
            ~taint:(read_tree [AccessPath.dictionary_keys] taint)
            ~state
            ~expression:key
        in
        let state =
          analyze_expression
            ~resolution
            ~taint:(read_tree [Abstract.TreeDomain.Label.AnyIndex] taint)
            ~state
            ~expression:value
        in
        analyze_generators ~resolution ~state generators
    | Generator comprehension -> analyze_comprehension ~resolution taint comprehension state
    | Lambda { parameters = _; body } ->
        (* Ignore parameter bindings and pretend body is inlined *)
        analyze_expression ~resolution ~taint ~state ~expression:body
    | List list ->
        let total = List.length list in
        List.rev list
        |> List.foldi ~f:(analyze_reverse_list_element ~total ~resolution taint) ~init:state
    | ListComprehension comprehension -> analyze_comprehension ~resolution taint comprehension state
    | Name _ when AccessPath.is_global ~resolution expression -> state
    | Name (Name.Identifier identifier) ->
        store_weak_taint ~root:(Root.Variable identifier) ~path:[] taint state
    | Name (Name.Attribute { base; attribute = "__dict__"; _ }) ->
        analyze_expression ~resolution ~taint ~state ~expression:base
    | Name (Name.Attribute { base; attribute; special }) ->
        analyze_attribute_access
          ~resolution
          ~location
          ~resolve_properties:true
          ~base
          ~attribute
          ~special
          ~base_taint:BackwardState.Tree.bottom
          ~attribute_taint:taint
          ~state
    | Set set ->
        let element_taint = read_tree [Abstract.TreeDomain.Label.AnyIndex] taint in
        List.fold
          set
          ~f:(fun state expression ->
            analyze_expression ~resolution ~taint:element_taint ~state ~expression)
          ~init:state
    | SetComprehension comprehension -> analyze_comprehension ~resolution taint comprehension state
    | Starred (Starred.Once expression)
    | Starred (Starred.Twice expression) ->
        let taint = BackwardState.Tree.prepend [Abstract.TreeDomain.Label.AnyIndex] taint in
        analyze_expression ~resolution ~taint ~state ~expression
    | FormatString substrings ->
        analyze_joined_string
          ~resolution
          ~taint
          ~state
          ~location:(Location.with_module ~qualifier:FunctionContext.qualifier location)
          substrings
    | Ternary { target; test; alternative } ->
        let state_then = analyze_expression ~resolution ~taint ~state ~expression:target in
        let state_else = analyze_expression ~resolution ~taint ~state ~expression:alternative in
        join state_then state_else
        |> fun state ->
        analyze_expression ~resolution ~taint:BackwardState.Tree.empty ~state ~expression:test
    | Tuple list ->
        let total = List.length list in
        List.rev list
        |> List.foldi ~f:(analyze_reverse_list_element ~total ~resolution taint) ~init:state
    | UnaryOperator { operator = _; operand } ->
        analyze_expression ~resolution ~taint ~state ~expression:operand
    | WalrusOperator { target; value } ->
        analyze_expression ~resolution ~taint ~state ~expression:value
        |> fun state -> analyze_expression ~resolution ~taint ~state ~expression:target
    | Yield None -> state
    | Yield (Some expression)
    | YieldFrom expression ->
        let access_path = { root = Root.LocalResult; path = [] } in
        let return_taint = get_taint (Some access_path) state in
        analyze_expression ~resolution ~taint:return_taint ~state ~expression


  (* Returns the taint, and whether to collapse one level (due to star expression) *)
  and compute_assignment_taint ~resolution target state =
    match target.Node.value with
    | Expression.Starred (Once target | Twice target) ->
        (* This is approximate. Unless we can get the tuple type on the right to tell how many total
           elements there will be, we just pick up the entire collection. *)
        let taint, _ = compute_assignment_taint ~resolution target state in
        taint, true
    | List targets
    | Tuple targets ->
        let compute_tuple_target_taint position taint_accumulator target =
          let taint, collapse = compute_assignment_taint ~resolution target state in
          let index_taint =
            if collapse then
              taint
            else
              let index_name = Abstract.TreeDomain.Label.Index (string_of_int position) in
              BackwardState.Tree.prepend [index_name] taint
          in
          BackwardState.Tree.join index_taint taint_accumulator
        in
        let taint =
          List.foldi targets ~f:compute_tuple_target_taint ~init:BackwardState.Tree.empty
        in
        taint, false
    | Call
        {
          callee = { Node.value = Name (Name.Attribute { base; attribute = "__getitem__"; _ }); _ };
          arguments = [{ Call.Argument.value = index; _ }];
        } ->
        let taint =
          compute_assignment_taint ~resolution base state
          |> fst
          |> BackwardState.Tree.read [AccessPath.get_index index]
        in
        taint, false
    | _ ->
        let taint =
          let local_taint =
            let access_path = of_expression ~resolution target in
            get_taint access_path state
          in
          let global_taint =
            let location =
              Location.with_module ~qualifier:FunctionContext.qualifier target.Node.location
            in
            Model.get_global_model ~resolution ~location ~expression:target
            |> Model.GlobalModel.get_sink
          in
          BackwardState.Tree.join local_taint global_taint
        in
        taint, false


  and analyze_assignment ~resolution ?(fields = []) ~target ~value state =
    let taint = compute_assignment_taint ~resolution target state |> fst |> read_tree fields in
    let state =
      let rec clear_taint state target =
        match Node.value target with
        | Expression.Tuple items -> List.fold items ~f:clear_taint ~init:state
        | _ -> (
            match of_expression ~resolution target with
            | Some { root; path } ->
                {
                  taint =
                    BackwardState.assign
                      ~root
                      ~path:(path @ fields)
                      BackwardState.Tree.empty
                      state.taint;
                }
            | None -> state)
      in
      clear_taint state target
    in
    analyze_expression ~resolution ~taint ~state ~expression:value


  let analyze_statement ~resolution state { Node.value = statement; _ } =
    match statement with
    | Statement.Statement.Assign
        { value = { Node.value = Expression.Constant Constant.Ellipsis; _ }; _ } ->
        state
    | Assign { target = { Node.location; value = target_value } as target; value; _ } -> (
        let target_is_sanitized =
          match target_value with
          | Name (Name.Attribute _) ->
              let location =
                Location.with_module ~qualifier:FunctionContext.qualifier target.Node.location
              in
              Model.get_global_model ~resolution ~location ~expression:target
              |> Model.GlobalModel.is_sanitized
          | _ -> false
        in
        if target_is_sanitized then
          analyze_expression ~resolution ~taint:BackwardState.Tree.bottom ~state ~expression:value
        else
          match target_value with
          | Expression.Name (Name.Attribute { base; attribute; _ }) -> (
              match get_property_callees ~location ~attribute with
              | Some { call_targets = _ :: _ as call_targets; return_type; _ } ->
                  (* Treat `a.property = x` as `a = a.property(x)` *)
                  let taint = compute_assignment_taint ~resolution base state |> fst in
                  apply_callees
                    ~resolution
                    ~callee:target
                    ~call_location:location
                    ~arguments:[{ name = None; value }]
                    ~state
                    ~call_taint:taint
                    (CallGraph.RawCallees.create ~call_targets ~return_type ())
              | _ -> analyze_assignment ~resolution ~target ~value state)
          | _ -> analyze_assignment ~resolution ~target ~value state)
    | Assert _
    | Break
    | Class _
    | Continue ->
        state
    | Define define -> analyze_definition ~define state
    | Delete expressions ->
        let process_expression state expression =
          match AccessPath.of_expression ~resolution expression with
          | Some { AccessPath.root; path } ->
              { taint = BackwardState.assign ~root ~path BackwardState.Tree.bottom state.taint }
          | _ -> state
        in
        List.fold expressions ~init:state ~f:process_expression
    | Expression expression ->
        analyze_expression ~resolution ~taint:BackwardState.Tree.empty ~state ~expression
    | For _
    | Global _
    | If _
    | Import _
    | Match _
    | Nonlocal _
    | Pass
    | Raise _ ->
        state
    | Return { expression = Some expression; _ } ->
        let access_path = { root = Root.LocalResult; path = [] } in
        let return_taint = get_taint (Some access_path) state in
        analyze_expression ~resolution ~taint:return_taint ~state ~expression
    | Return { expression = None; _ }
    | Try _
    | With _
    | While _ ->
        state


  let backward ~statement_key state ~statement =
    TaintProfiler.track_statement_analysis
      ~profiler
      ~analysis:TaintProfiler.Backward
      ~statement
      ~f:(fun () ->
        log
          "Backward analysis of statement: `%a`@,With backward state: %a"
          Statement.pp
          statement
          pp
          state;
        let resolution =
          let { Node.value = { Statement.Define.signature = { parent; _ }; _ }; _ } =
            FunctionContext.definition
          in
          TypeCheck.resolution_with_key
            ~global_resolution
            ~local_annotations
            ~parent
            ~statement_key
            (* TODO(T65923817): Eliminate the need of creating a dummy context here *)
            (module TypeCheck.DummyContext)
        in
        analyze_statement ~resolution state statement)


  let forward ~statement_key:_ _ ~statement:_ = failwith "Don't call me"
end

(* Split the inferred entry state into externally visible taint_in_taint_out parts and sink_taint. *)
let extract_tito_and_sink_models define ~is_constructor ~resolution ~existing_backward entry_taint =
  let { Statement.Define.signature = { parameters; _ }; _ } = define in
  let {
    TaintConfiguration.analysis_model_constraints =
      {
        maximum_model_width;
        maximum_return_access_path_length;
        maximum_trace_length;
        maximum_tito_depth;
        _;
      };
    _;
  }
    =
    TaintConfiguration.get ()
  in
  let normalized_parameters = AccessPath.Root.normalize_parameters parameters in
  (* Simplify trees by keeping only essential structure and merging details back into that. *)
  let simplify annotation tree =
    let annotation = Option.map ~f:(GlobalResolution.parse_annotation resolution) annotation in
    let type_breadcrumbs = Features.type_breadcrumbs ~resolution annotation in

    let essential =
      if is_constructor then
        BackwardState.Tree.essential_for_constructor tree
      else
        BackwardState.Tree.essential tree
    in
    BackwardState.Tree.shape
      ~transform:(BackwardTaint.add_breadcrumbs (Features.widen_broadening_set ()))
      tree
      ~mold:essential
    |> BackwardState.Tree.add_breadcrumbs type_breadcrumbs
    |> BackwardState.Tree.limit_to
         ~transform:(BackwardTaint.add_breadcrumbs (Features.widen_broadening_set ()))
         ~width:maximum_model_width
    |> BackwardState.Tree.approximate_return_access_paths ~maximum_return_access_path_length
  in

  let split_and_simplify model (parameter, name, original) =
    let annotation = original.Node.value.Parameter.annotation in
    let partition =
      BackwardState.read ~root:(Root.Variable name) ~path:[] entry_taint
      |> BackwardState.Tree.partition BackwardTaint.kind By ~f:Sinks.discard_transforms
    in
    let taint_in_taint_out =
      let breadcrumbs_to_attach, via_features_to_attach =
        BackwardState.extract_features_to_attach
          ~root:parameter
          ~attach_to_kind:Sinks.Attach
          existing_backward.TaintResult.Backward.taint_in_taint_out
      in
      let candidate_tree =
        Map.Poly.find partition Sinks.LocalReturn
        |> Option.value ~default:BackwardState.Tree.empty
        |> simplify annotation
      in
      let candidate_tree =
        match maximum_tito_depth with
        | Some maximum_tito_depth ->
            BackwardState.Tree.prune_maximum_length maximum_tito_depth candidate_tree
        | _ -> candidate_tree
      in
      let candidate_tree =
        candidate_tree
        |> BackwardState.Tree.add_breadcrumbs breadcrumbs_to_attach
        |> BackwardState.Tree.add_via_features via_features_to_attach
      in
      let number_of_paths =
        BackwardState.Tree.fold
          BackwardState.Tree.Path
          ~init:0
          ~f:(fun _ count -> count + 1)
          candidate_tree
      in
      if number_of_paths > TaintConfiguration.maximum_tito_leaves then
        BackwardState.Tree.collapse_to
          ~transform:(BackwardTaint.add_breadcrumbs (Features.widen_broadening_set ()))
          ~depth:0
          candidate_tree
      else
        candidate_tree
    in
    let sink_taint =
      let simplify_sink_taint ~key:sink ~data:sink_tree accumulator =
        match sink with
        | Sinks.LocalReturn
        (* For now, we don't propagate partial sinks at all. *)
        | Sinks.PartialSink _
        | Sinks.Attach ->
            accumulator
        | _ ->
            let sink_tree =
              match maximum_trace_length with
              | Some maximum_trace_length ->
                  BackwardState.Tree.prune_maximum_length maximum_trace_length sink_tree
              | _ -> sink_tree
            in
            simplify annotation sink_tree |> BackwardState.Tree.join accumulator
      in
      Map.Poly.fold ~init:BackwardState.Tree.empty ~f:simplify_sink_taint partition
    in
    let sink_taint =
      let breadcrumbs_to_attach, via_features_to_attach =
        BackwardState.extract_features_to_attach
          ~root:parameter
          ~attach_to_kind:Sinks.Attach
          existing_backward.TaintResult.Backward.sink_taint
      in
      sink_taint
      |> BackwardState.Tree.add_breadcrumbs breadcrumbs_to_attach
      |> BackwardState.Tree.add_via_features via_features_to_attach
    in
    TaintResult.Backward.
      {
        taint_in_taint_out =
          BackwardState.assign ~root:parameter ~path:[] taint_in_taint_out model.taint_in_taint_out;
        sink_taint = BackwardState.assign ~root:parameter ~path:[] sink_taint model.sink_taint;
      }
  in
  List.fold normalized_parameters ~f:split_and_simplify ~init:TaintResult.Backward.empty


let run
    ?(profiler = TaintProfiler.none)
    ~environment
    ~qualifier
    ~define
    ~call_graph_of_define
    ~existing_model
    ~triggered_sinks
  =
  let timer = Timer.start () in
  let ({ Node.value = { Statement.Define.signature = { name; _ }; _ }; _ } as define) =
    (* Apply decorators to make sure we match parameters up correctly. *)
    let resolution = TypeEnvironment.ReadOnly.global_resolution environment in
    Annotated.Define.create define
    |> Annotated.Define.decorate ~resolution
    |> Annotated.Define.define
  in
  let module FunctionContext = struct
    let qualifier = qualifier

    let definition = define

    let debug = Statement.Define.dump define.value

    let profiler = profiler

    let environment = environment

    let call_graph_of_define = call_graph_of_define

    let triggered_sinks = triggered_sinks
  end
  in
  let module State = State (FunctionContext) in
  let module Fixpoint = Fixpoint.Make (State) in
  let initial = State.{ taint = initial_taint } in
  let cfg = Cfg.create define.value in
  let () = State.log "Backward analysis of callable: `%a`" Reference.pp name in
  let entry_state =
    Metrics.with_alarm name (fun () -> Fixpoint.backward ~cfg ~initial |> Fixpoint.entry) ()
  in
  let () =
    match entry_state with
    | Some entry_state -> State.log "Entry state:@,%a" State.pp entry_state
    | None -> State.log "No entry state found"
  in
  let resolution = TypeEnvironment.ReadOnly.global_resolution environment in
  let extract_model State.{ taint; _ } =
    let model =
      extract_tito_and_sink_models
        ~is_constructor:(State.is_constructor ())
        define.value
        ~resolution
        ~existing_backward:existing_model.TaintResult.backward
        taint
    in
    let () = State.log "Backward Model:@,%a" TaintResult.Backward.pp_model model in
    model
  in
  Statistics.performance
    ~randomly_log_every:1000
    ~always_log_time_threshold:1.0 (* Seconds *)
    ~name:"Backward analysis"
    ~normals:["callable", Reference.show name]
    ~section:`Taint
    ~timer
    ();

  entry_state >>| extract_model |> Option.value ~default:TaintResult.Backward.empty
