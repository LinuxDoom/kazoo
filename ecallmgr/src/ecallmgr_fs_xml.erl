%%%-------------------------------------------------------------------
%%% @copyright (C) 2011, VoIP INC
%%% @doc
%%% Generate the XML for various FS responses
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(ecallmgr_fs_xml).

-export([build_sip_route/2, build_freetdm_route/1
         ,get_leg_vars/1, get_channel_vars/1, get_channel_vars/2
         ,route_resp_xml/1 ,authn_resp_xml/1, config_acl_xml/1
        ]).

-include("ecallmgr.hrl").

authn_resp_xml([_|_]=RespProp) ->
    authn_resp_xml(props:get_value(<<"Auth-Method">>, RespProp), wh_json:from_list(RespProp));
authn_resp_xml(RespJObj) ->
    authn_resp_xml(wh_json:get_value(<<"Auth-Method">>, RespJObj), RespJObj).

authn_resp_xml(<<"password">>, JObj) ->
    User = wh_json:get_value(<<"Auth-User">>, JObj),
    Realm = wh_json:get_value(<<"Auth-Realm">>, JObj),
    Pass = wh_json:get_value(<<"Auth-Password">>, JObj),
    ChannelParams = get_channel_params(JObj),
    {ok, lists:flatten(io_lib:format(?REGISTER_PASS_RESPONSE, [Realm, User, Pass, ChannelParams]))};
authn_resp_xml(<<"a1-hash">>, JObj) ->
    User = wh_json:get_value(<<"Auth-User">>, JObj),
    Realm = wh_json:get_value(<<"Auth-Realm">>, JObj),
    Hash = wh_json:get_value(<<"Auth-Password">>, JObj),
    ChannelParams = get_channel_params(JObj),
    {ok, lists:flatten(io_lib:format(?REGISTER_HASH_RESPONSE, [Realm, User, Hash, ChannelParams]))};
authn_resp_xml(<<"ip">>, _JObj) ->
    {ok, ?EMPTYRESPONSE};
authn_resp_xml(_Method, _JObj) ->
    lager:debug("unknown method ~s", [_Method]),
    {ok, ?EMPTYRESPONSE}.

route_resp_xml([_|_]=RespProp) ->
    route_resp_xml(props:get_value(<<"Method">>, RespProp), props:get_value(<<"Routes">>, RespProp), wh_json:from_list(RespProp));
route_resp_xml(RespJObj) ->
    route_resp_xml(wh_json:get_value(<<"Method">>, RespJObj), wh_json:get_value(<<"Routes">>, RespJObj), RespJObj).

config_acl_xml({struct, Acls}) ->
    FNodes = fun({_, JObj}, AccJObj) ->
                  Type = wh_json:get_value(<<"network-list-name">>, JObj),
              
                  %ensure Type exists as a key
                  Acc = case wh_json:get_value(Type, AccJObj, undefined) of
                            undefined -> wh_json:set_value(Type, [],  AccJObj);
                            _ -> AccJObj
                       end,
                  
                  Acl = [wh_json:get_value(<<"type">>, JObj), wh_json:get_value(<<"cidr">>, JObj)],
                  wh_json:set_value(Type, [io_lib:format(?CONFIG_ACL_NODE, Acl) | wh_json:get_value(Type, Acc)], Acc)
             end,

    Nodes = lists:foldl(FNodes, wh_json:new(), Acls),

    FLists = fun({ListName, ListNodes}, Acc) ->
                [io_lib:format(?CONFIG_ACL_LIST, [ListName, lists:flatten(ListNodes)]) |Acc]  
             end,
    Lists = lists:foldl(FLists, [], wh_json:to_proplist(Nodes)),
    {ok, lists:flatten(io_lib:format(?CONFIG_ACL, [lists:flatten(Lists)]))}.

%% Prop = Route Response
-spec route_resp_xml/3 :: (binary(), wh_json:json_objects(), wh_json:json_object()) -> {'ok', iolist()}.
route_resp_xml(<<"bridge">>, Routes, _JObj) ->
    lager:debug("creating a bridge XML response"),
    %% format the Route based on protocol
    {_Idx, Extensions, Errors} = lists:foldr(
                                   fun(RouteJObj, {Idx, Acc, ErrAcc}) ->
                                           case build_sip_route(RouteJObj, wh_json:get_value(<<"Invite-Format">>, RouteJObj)) of
                                               {error, timeout} ->
                                                   {Idx+1, Acc, ErrAcc};
                                               Route ->
                                                   BypassMedia = case wh_json:get_value(<<"Media">>, RouteJObj) of
                                                                     <<"bypass">> -> "true";
                                                                     _ -> "false" %% default to not bypassing media
                                                                 end,

                                                   RouteJObj1 = case wh_json:get_value(<<"Progress-Timeout">>, RouteJObj) of
                                                                    undefined ->
                                                                        wh_json:set_value(<<"Progress-Timeout">>, <<"6">>, RouteJObj);
                                                                    I when is_integer(I) ->
                                                                        wh_json:set_value(<<"Progress-Timeout">>, integer_to_list(I), RouteJObj);
                                                                    _ -> RouteJObj
                                                                end,

                                                   ChannelVars = get_channel_vars(wh_json:to_proplist(RouteJObj1)),
                                                   {Idx+1
                                                    ,[io_lib:format(?ROUTE_BRIDGE_EXT, [Idx, BypassMedia, ChannelVars, Route]) | Acc]
                                                    , ErrAcc}
                                           end
                                   end, {1, "", ""}, Routes),
    case Extensions of
        [] ->
            lager:debug("No endpoints to route to"),
            {ok, lists:flatten(io_lib:format(?ROUTE_BRIDGE_RESPONSE, [?WHISTLE_CONTEXT, Errors]))};
        _ ->
            Xml = io_lib:format(?ROUTE_BRIDGE_RESPONSE, [?WHISTLE_CONTEXT, Extensions]),
            lager:debug("Bridge XML generated: ~s", [Xml]),
            {ok, lists:flatten(Xml)}
    end;
route_resp_xml(<<"park">>, _Routes, _JObj) ->
    Park = lists:flatten(io_lib:format(?ROUTE_PARK_RESPONSE, [?WHISTLE_CONTEXT])),
    lager:debug("Creating park XML: ~s", [Park]),
    {ok, Park};
route_resp_xml(<<"error">>, _Routes, JObj) ->
    ErrCode = wh_json:get_value(<<"Route-Error-Code">>, JObj),
    ErrMsg = list_to_binary([" ", wh_json:get_value(<<"Route-Error-Message">>, JObj, <<"">>)]),
    Xml = io_lib:format(?ROUTE_ERROR_RESPONSE, [?WHISTLE_CONTEXT, ErrCode, ErrMsg]),
    lager:debug("Creating error XML: ~s", [Xml]),
    {ok, lists:flatten(Xml)}.

-spec build_sip_route/2 :: (proplist() | wh_json:json_object(), ne_binary() | 'undefined') -> ne_binary() | {'error', 'timeout'}.
build_sip_route(Route, undefined) ->
    build_sip_route(Route, <<"username">>);
build_sip_route([_|_]=RouteProp, DIDFormat) ->
    build_sip_route(wh_json:from_list(RouteProp), DIDFormat);
build_sip_route(RouteJObj, <<"route">>) ->
    case wh_json:get_value(<<"Route">>, RouteJObj) of
        <<"sip:", _/binary>> = R1 -> <<?SIP_INTERFACE, (R1)/binary>>;
        R2 -> R2
    end;
build_sip_route(RouteJObj, <<"username">>) ->
    User = wh_json:get_value(<<"To-User">>, RouteJObj),
    Realm = wh_json:get_value(<<"To-Realm">>, RouteJObj),
    case ecallmgr_registrar:lookup_contact(Realm, User) of
        {ok, Contact} ->
            RURI = binary:replace(re:replace(Contact, "^[^\@]+", User, [{return, binary}]), <<">">>, <<"">>),
            <<?SIP_INTERFACE, (RURI)/binary>>;
        {error, timeout}=E ->
            lager:debug("failed to lookup user ~s@~s in the registrar", [User, Realm]),
            E
    end;
build_sip_route(RouteJObj, DIDFormat) ->
    User = wh_json:get_value(<<"To-User">>, RouteJObj),
    Realm = wh_json:get_value(<<"To-Realm">>, RouteJObj),
    DID = format_did(wh_json:get_value(<<"To-DID">>, RouteJObj), DIDFormat),
    case ecallmgr_registrar:lookup_contact(Realm, User) of
        {ok, Contact} ->
            RURI = binary:replace(re:replace(Contact, "^[^\@]+", DID, [{return, binary}]), <<">">>, <<"">>),
            <<?SIP_INTERFACE, (RURI)/binary>>;
        {error, timeout}=E ->
            lager:debug("failed to lookup user ~s@~s in the registrar", [User, Realm]),
            E
    end.

build_freetdm_route(EndpointJObj) ->
    Opts = wh_json:get_value(<<"Endpoint-Options">>, EndpointJObj, wh_json:new()),
    Span = wh_json:get_binary_value(<<"Span">>, Opts, <<"1">>),
    StartFrom = case wh_json:get_binary_value(<<"Channel-Selection">>, Opts) of
                    <<"descending">> -> <<"A">>;
                    _ -> <<"a">>
                end,
    DID = format_did(wh_json:get_binary_value(<<"To-DID">>, EndpointJObj), wh_json:get_value(<<"Invite-Format">>, EndpointJObj, <<"e164">>)),

    lager:debug("freetdm/span: ~s/start: ~s/DID: ~s", [Span, StartFrom, DID]),

    [<<"freetdm/">>, Span, <<"/">>, StartFrom, <<"/">>, DID].

-spec format_did/2 :: (ne_binary(), ne_binary()) -> ne_binary().
format_did(DID, <<"e164">>) ->
    wnm_util:to_e164(DID);
format_did(DID, <<"npan">>) ->
    wnm_util:to_npan(DID);
format_did(DID, <<"1npan">>) ->
    wnm_util:to_1npan(DID);
format_did(DID, _) ->
    DID.

-spec get_leg_vars/1 :: (wh_json:json_object() | proplist()) -> [nonempty_string(),...].
get_leg_vars([_|_]=Prop) ->
    ["[", string:join([wh_util:to_list(V) || V <- lists:foldr(fun get_channel_vars/2, [], Prop)], ","), "]"];
get_leg_vars(JObj) -> get_leg_vars(wh_json:to_proplist(JObj)).

-spec get_channel_vars/1 :: (wh_json:json_object() | proplist()) -> [nonempty_string(),...].
get_channel_vars([_|_]=Prop) ->
    P = Prop ++ [{<<"Overwrite-Channel-Vars">>, <<"true">>}],
    ["{", string:join([wh_util:to_list(V) || V <- lists:foldr(fun get_channel_vars/2, [], P)], ","), "}"];
get_channel_vars(JObj) -> get_channel_vars(wh_json:to_proplist(JObj)).

-spec get_channel_vars/2 :: ({binary(), binary() | wh_json:json_object()}, [binary(),...] | []) -> [binary(),...] | [].
get_channel_vars({<<"Custom-Channel-Vars">>, JObj}, Vars) ->
    lists:foldl(fun({K, V}, Acc) ->
                        case lists:keyfind(K, 1, ?SPECIAL_CHANNEL_VARS) of
                            false -> [list_to_binary([?CHANNEL_VAR_PREFIX, wh_util:to_list(K)
                                                      ,"='", wh_util:to_list(V), "'"]) | Acc];
                            {_, Prefix} -> [list_to_binary([Prefix, "='", wh_util:to_list(V), "'"]) | Acc]
                        end
                end, Vars, wh_json:to_proplist(JObj));

get_channel_vars({<<"SIP-Headers">>, SIPJObj}, Vars) ->
    SIPHeaders = wh_json:to_proplist(SIPJObj),
    lists:foldl(fun({K,V}, Vars0) ->
                        [ list_to_binary(["sip_h_", K, "=", V]) | Vars0]
                end, Vars, SIPHeaders);

get_channel_vars({<<"Caller-ID-Type">>, <<"from">>}, Vars) ->
    [ <<"sip_cid_type=none">> | Vars];
get_channel_vars({<<"Caller-ID-Type">>, <<"rpid">>}, Vars) ->
    [ <<"sip_cid_type=rpid">> | Vars];
get_channel_vars({<<"Caller-ID-Type">>, <<"pid">>}, Vars) ->
    [ <<"sip_cid_type=pid">> | Vars];

get_channel_vars({<<"origination_uuid">> = K, UUID}, Vars) ->
    [ <<K/binary, "=", UUID/binary>> | Vars];

get_channel_vars({<<"Hold-Media">>, Media}, Vars) ->
    [list_to_binary(["hold_music="
                     ,wh_util:to_list(ecallmgr_util:media_path(Media, extant, get(callid)))
                    ]) | Vars];

get_channel_vars({<<"Codecs">>, []}, Vars) ->
    Vars;
get_channel_vars({<<"Codecs">>, Cs}, Vars) ->
    Codecs = [ wh_util:to_list(C) || C <- Cs, not wh_util:is_empty(C) ],
    CodecStr = string:join(Codecs, ","),
    [ list_to_binary(["codec_string='", CodecStr, "'"]) | Vars];

%% SPECIAL CASE: Timeout must be larger than zero
get_channel_vars({<<"Timeout">>, V}, Vars) ->
    case wh_util:to_integer(V) of
        TO when TO > 0 ->
            [ <<"call_timeout=", (wh_util:to_binary(TO))/binary>> | Vars];
        _Else ->
            Vars
    end;

get_channel_vars({AMQPHeader, V}, Vars) when not is_list(V) ->
    case lists:keyfind(AMQPHeader, 1, ?SPECIAL_CHANNEL_VARS) of
        false -> Vars;
        {_, Prefix} -> [list_to_binary([Prefix, "='", wh_util:to_list(V), "'"]) | Vars]
    end;

get_channel_vars(_, Vars) ->
    Vars.


get_channel_params(JObj) ->
    CV0 = case wh_json:get_value(<<"Tenant-ID">>, JObj) of
              undefined -> [];
              TID -> [io_lib:format(?REGISTER_CHANNEL_PARAM
                                    ,[list_to_binary([?CHANNEL_VAR_PREFIX, "Tenant-ID"]), TID])]
          end,

    CV1 = case wh_json:get_value(<<"Access-Group">>, JObj) of
              undefined -> CV0;
              AG -> [io_lib:format(?REGISTER_CHANNEL_PARAM
                                   ,[list_to_binary([?CHANNEL_VAR_PREFIX, "Access-Group"]), AG]) | CV0]
          end,

    Custom = wh_json:to_proplist(wh_json:get_value(<<"Custom-Channel-Vars">>, JObj, wh_json:new())),
    lists:foldl(fun({K,V}, CV) ->
                        [io_lib:format(?REGISTER_CHANNEL_PARAM
                                       ,[list_to_binary([?CHANNEL_VAR_PREFIX, K]), V]) | CV]
                end, CV1, Custom).
