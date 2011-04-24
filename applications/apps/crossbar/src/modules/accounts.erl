%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%% Account module
%%%
%%% Handle client requests for account documents
%%%
%%% @end
%%% Created : 05 Jan 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(accounts).

-behaviour(gen_server).

%% API
-export([start_link/0, update_all_accounts/1, replicate_from_accounts/2, 
         replicate_from_account/3, get_db_name/1, get_db_name/2, create_account/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("../../include/crossbar.hrl").

-define(SERVER, ?MODULE).

-define(VIEW_FILE, <<"views/account.json">>).

-define(AGG_DB, <<"accounts">>).
-define(AGG_VIEW_FILE, <<"views/accounts.json">>).
-define(AGG_VIEW_SUMMARY, <<"accounts/listing_by_id">>).
-define(AGG_VIEW_PARENT, <<"accounts/listing_by_parent">>).
-define(AGG_VIEW_CHILDREN, <<"accounts/listing_by_children">>).
-define(AGG_VIEW_DESCENDANTS, <<"accounts/listing_by_descendants">>).
-define(AGG_GROUP_BY_REALM, <<"accounts/group_by_realm">>).
-define(AGG_FILTER, <<"account/export">>).

-define(REPLICATE_ENCODING, encoded).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% Update a document in each crossbar account database with the
%% file contents.  This is intended for _design docs....
%%
%% @spec update_all_accounts() -> ok | error
%% @end
%%--------------------------------------------------------------------
-spec(update_all_accounts/1 :: (File :: binary()) -> no_return()).
update_all_accounts(File) ->
    {ok, Databases} = couch_mgr:db_info(),
    lists:foreach(fun(ClientDb) ->
                          case couch_mgr:update_doc_from_file(ClientDb, crossbar, File) of
                              {error, _} ->
                                  couch_mgr:load_doc_from_file(ClientDb, crossbar, File);
                              {ok, _} -> ok
                          end
                  end, [get_db_name(Db, encoded) || Db <- Databases, fun(<<"account/", _/binary>>) -> true; (_) -> false end(Db)]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(replicate_from_accounts/2 :: (TargetDb :: binary(), FilterDoc :: binary()) -> no_return()).
replicate_from_accounts(TargetDb, FilterDoc) when is_binary(FilterDoc) ->
    {ok, Databases} = couch_mgr:db_info(),
    BaseReplicate = [{<<"target">>, TargetDb}
                     ,{<<"filter">>, FilterDoc}
                     ,{<<"create_target">>, true}
                     ,{<<"continuous">>, true}
                    ],
    lists:foreach(fun(SourceDb) ->
                          logger:format_log(info, "Replicate ~p to ~p using filter ~p", [SourceDb, TargetDb, FilterDoc]),
                          couch_mgr:db_replicate([{<<"source">>, SourceDb} | BaseReplicate])
                  end, [get_db_name(Db, ?REPLICATE_ENCODING) || Db <- Databases, fun(<<"account", _/binary>>) -> true; (_) -> false end(Db)]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(replicate_from_account/3 :: (SourceDb :: binary(), TargetDb :: binary(), FilterDoc :: binary()) -> no_return()).
replicate_from_account(SourceDb, TargetDb, FilterDoc) ->
    BaseReplicate = [{<<"source">>, get_db_name(SourceDb, ?REPLICATE_ENCODING)}
                     ,{<<"target">>, TargetDb}
                     ,{<<"filter">>, FilterDoc}
                     ,{<<"create_target">>, true}
                     ,{<<"continuous">>, true}
                    ],
    logger:format_log(info, "Replicate ~p to ~p using filter ~p", [get_db_name(SourceDb, ?REPLICATE_ENCODING), TargetDb, FilterDoc]),
    couch_mgr:db_replicate(BaseReplicate).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(_) ->
    {ok, ok, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({binding_fired, Pid, <<"v1_resource.allowed_methods.accounts">>, Payload}, State) ->
    spawn(fun() ->
                  {Result, Payload1} = allowed_methods(Payload),
                  Pid ! {binding_result, Result, Payload1}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.resource_exists.accounts">>, Payload}, State) ->
    spawn(fun() ->
                  {Result, Payload1} = resource_exists(Payload),
                  Pid ! {binding_result, Result, Payload1}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.accounts">>, [RD, #cb_context{req_nouns=[{<<"accounts">>, _}]}=Context | Params]}, State) ->
    spawn(fun() ->                  
                  crossbar_util:binding_heartbeat(Pid),
                  %% Do all of our prep-work out of the agg db
                  %% later we will switch to save to the client db
                  Context1 = validate(Params, Context#cb_context{db_name=?AGG_DB}),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.validate.accounts">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  Context1 = load_account_db(Params, Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.accounts">>, [RD, Context | [AccountId, <<"parent">>]=Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:binding_heartbeat(Pid),
                  case crossbar_doc:save(Context#cb_context{db_name=get_db_name(AccountId, encoded)}) of
                      #cb_context{resp_status=success}=Context1 ->
                          Pid ! {binding_result, true, [RD, Context1#cb_context{resp_data={struct, []}}, Params]};
                      Else ->
                          Pid ! {binding_result, true, [RD, Else, Params]}
                  end
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.post.accounts">>, [RD, Context | [AccountId]=Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:binding_heartbeat(Pid),
                  Context1 = crossbar_doc:save(Context#cb_context{db_name=get_db_name(AccountId, encoded)}),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

handle_info({binding_fired, Pid, <<"v1_resource.execute.put.accounts">>, [RD, Context | Params]}, State) ->
    spawn(fun() ->
                  crossbar_util:binding_heartbeat(Pid),
                  Context1 = create_new_account_db(Context),
                  Pid ! {binding_result, true, [RD, Context1, Params]}
          end),
    {noreply, State};

%handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.accounts">>, [RD, #cb_context{doc=Doc}=Context | [_, <<"parent">>]=Params]}, State) ->
%    %%spawn(fun() ->
%                  Doc1 = crossbar_util:set_json_values(<<"pvt_tree">>, [], Doc),
%                  Context1 = crossbar_doc:save(Context#cb_context{db_name=?AGG_DB, doc=Doc1}),
%                  Pid ! {binding_result, true, [RD, Context1, Params]},
%       %%  end),
%    {noreply, State};
%
%handle_info({binding_fired, Pid, <<"v1_resource.execute.delete.accounts">>, [RD, Context | Params]}, State) ->
%    spawn(fun() ->
%                  Context1 = crossbar_doc:delete(Context),
%                  Pid ! {binding_result, true, [RD, Context1, Params]}
%         end),
%    {noreply, State};

handle_info({binding_fired, Pid, _, Payload}, State) ->
    Pid ! {binding_result, false, Payload},
    {noreply, State};

handle_info(timeout, State) ->
    bind_to_crossbar(),
    couch_mgr:db_create(?AGG_DB),
    case couch_mgr:update_doc_from_file(?AGG_DB, crossbar, ?AGG_VIEW_FILE) of
        {error, _} ->
            couch_mgr:load_doc_from_file(?AGG_DB, crossbar, ?AGG_VIEW_FILE);
        {ok, _} -> ok
    end,
    update_all_accounts(?VIEW_FILE),
    replicate_from_accounts(?AGG_DB, ?AGG_FILTER),
    {noreply, State};

handle_info(_Info, State) ->
    logger:format_log(info, "ACCOUNTS(~p): unhandled info ~p~n", [self(), _Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function binds this server to the crossbar bindings server,
%% for the keys we need to consume.
%% @end
%%--------------------------------------------------------------------
-spec(bind_to_crossbar/0 :: () ->  no_return()).
bind_to_crossbar() ->
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.accounts">>),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.accounts">>),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.accounts">>),
    crossbar_bindings:bind(<<"v1_resource.execute.#.accounts">>).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec(allowed_methods/1 :: (Paths :: list()) -> tuple(boolean(), http_methods())).
allowed_methods([]) ->
    {true, ['GET', 'PUT']};
allowed_methods([_]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, <<"parent">>]) ->
    {true, ['GET', 'POST', 'DELETE']};
allowed_methods([_, Path]) ->
    Valid = lists:member(Path, [<<"ancestors">>, <<"children">>, <<"descendants">>, <<"siblings">>]),
    {Valid, ['GET']};
allowed_methods(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec(resource_exists/1 :: (Paths :: list()) -> tuple(boolean(), [])).
resource_exists([]) ->
    {true, []};
resource_exists([_]) ->
    {true, []};
resource_exists([_, Path]) ->
    Valid = lists:member(Path, [<<"parent">>, <<"ancestors">>, <<"children">>, <<"descendants">>, <<"siblings">>]),
    {Valid, []};
resource_exists(_) ->
    {false, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec(validate/2 :: (Params :: list(), Context :: #cb_context{}) -> #cb_context{}).
validate([], #cb_context{req_verb = <<"get">>}=Context) ->
    load_account_summary([], Context);
validate([], #cb_context{req_verb = <<"put">>}=Context) ->
    create_account(Context);
validate([AccountId], #cb_context{req_verb = <<"get">>}=Context) ->
    load_account(AccountId, Context);
validate([AccountId], #cb_context{req_verb = <<"post">>}=Context) ->
    update_account(AccountId, Context);
validate([AccountId], #cb_context{req_verb = <<"delete">>}=Context) ->
    load_account(AccountId, Context);
validate([AccountId, <<"parent">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_parent(AccountId, Context);
validate([AccountId, <<"parent">>], #cb_context{req_verb = <<"post">>}=Context) ->
    update_parent(AccountId, Context);
validate([AccountId, <<"parent">>], #cb_context{req_verb = <<"delete">>}=Context) ->
    load_account(AccountId, Context);
validate([AccountId, <<"children">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_children(AccountId, Context);
validate([AccountId, <<"descendants">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_descendants(AccountId, Context);
validate([AccountId, <<"siblings">>], #cb_context{req_verb = <<"get">>}=Context) ->
    load_siblings(AccountId, Context);
validate(_, Context) ->
    crossbar_util:response_faulty_request(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec(load_account_summary/2 :: (AccountId :: binary() | [], Context :: #cb_context{}) -> #cb_context{}).
load_account_summary([], Context) ->
    crossbar_doc:load_view(?AGG_VIEW_SUMMARY, [], Context, fun normalize_view_results/2);
load_account_summary(AccountId, Context) ->
    crossbar_doc:load_view(?AGG_VIEW_SUMMARY, [
         {<<"startkey">>, [AccountId]}
        ,{<<"endkey">>, [AccountId, {struct, []}]}
    ], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new account document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec(create_account/1 :: (Context :: #cb_context{}) -> #cb_context{}).
create_account(#cb_context{req_data=JObj}=Context) ->
    case is_valid_doc(JObj) of
        %% {false, Fields} ->
        %%     crossbar_util:response_invalid_data(Fields, Context);
        {true, []} ->
            case is_unique_realm(undefined, Context) of
                true ->
                    Context#cb_context{
                      doc=set_private_fields(JObj)
                      ,resp_status=success
                     };
                false ->
                    crossbar_util:response_invalid_data([<<"realm">>], Context)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load an account document from the database
%% @end
%%--------------------------------------------------------------------
-spec(load_account/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_account(AccountId, Context) ->
    crossbar_doc:load(AccountId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing account document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec(update_account/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
update_account(AccountId, #cb_context{req_data=Data}=Context) ->
    case is_valid_doc(Data) of
        %% {false, Fields} ->
        %%     crossbar_util:response_invalid_data(Fields, Context);
        {true, []} ->
            case is_unique_realm(AccountId, Context) of
                true ->
                    crossbar_doc:load_merge(AccountId, Data, Context);
                false ->
                    crossbar_util:response_invalid_data([<<"realm">>], Context)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load a summary of the parent of the account
%% @end
%%--------------------------------------------------------------------
-spec(load_parent/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_parent(AccountId, Context) ->
    View =
        crossbar_doc:load_view(?AGG_VIEW_PARENT, [
             {<<"startkey">>, AccountId}
            ,{<<"endkey">>, AccountId}
        ], Context),
    case View#cb_context.doc of
        [JObj|_] ->
            Parent = whapps_json:get_value([<<"value">>, <<"id">>], JObj),
            load_account_summary(Parent, Context);
        _Else ->
            crossbar_util:response_bad_identifier(AccountId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update the tree with a new parent, cascading when necessary, if the
%% new parent is valid
%% @end
%%--------------------------------------------------------------------
-spec(update_parent/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
update_parent(AccountId, #cb_context{req_data=Data}=Context) ->
    case is_valid_parent(Data) of
        %% {false, Fields} ->
        %%     crossbar_util:response_invalid_data(Fields, Context);
        {true, []} ->
            %% OMGBBQ! NO CHECKS FOR CYCLIC REFERENCES WATCH OUT!
            ParentId = props:get_value(<<"parent">>, element(2, Data)),
            update_tree(AccountId, ParentId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a summary of the children of this account
%% @end
%%--------------------------------------------------------------------
-spec(load_children/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_children(AccountId, Context) ->
    crossbar_doc:load_view(?AGG_VIEW_CHILDREN, [
         {<<"startkey">>, [AccountId]}
        ,{<<"endkey">>, [AccountId, {struct, []}]}
    ], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a summary of the descendants of this account
%% @end
%%--------------------------------------------------------------------
-spec(load_descendants/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_descendants(AccountId, Context) ->
    crossbar_doc:load_view(?AGG_VIEW_DESCENDANTS, [
         {<<"startkey">>, [AccountId]}
        ,{<<"endkey">>, [AccountId, {struct, []}]}
    ], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a summary of the siblngs of this account
%% @end
%%--------------------------------------------------------------------
-spec(load_siblings/2 :: (AccountId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
load_siblings(AccountId, Context) ->
    View =
        crossbar_doc:load_view(?AGG_VIEW_PARENT, [
             {<<"startkey">>, AccountId}
            ,{<<"endkey">>, AccountId}
        ], Context),
    case View#cb_context.doc of
        [JObj|_] ->
            Parent = whapps_json:get_value([<<"value">>, <<"id">>], JObj),
            load_children(Parent, Context);
        _Else ->
            crossbar_util:response_bad_identifier(AccountId, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec(normalize_view_results/2 :: (JObj :: json_object(), Acc :: json_objects()) -> json_objects()).
normalize_view_results(JObj, Acc) ->
    [whapps_json:get_value(<<"value">>, JObj)|Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(is_valid_parent/1 :: (JObj :: json_object()) -> tuple(true, [])). %tuple(boolean(), list())).
is_valid_parent({struct, [_]}) ->
    {true, []};
is_valid_parent(_JObj) ->
    {true, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(is_valid_doc/1 :: (JObj :: json_object()) -> tuple(true, json_objects())).
is_valid_doc(_JObj) ->
    {true, []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(update_tree/3 :: (AccountId :: binary(), ParentId :: binary(), Context :: #cb_context{}) -> #cb_context{}).
update_tree(AccountId, ParentId, Context) ->
    case crossbar_doc:load(ParentId, Context) of
        #cb_context{resp_status=success, doc=Parent} ->
            Descendants =
                crossbar_doc:load_view(?AGG_VIEW_DESCENDANTS, [
                     {<<"startkey">>, [AccountId]}
                    ,{<<"endkey">>, [AccountId, {struct, []}]}
                ], Context),
            case Descendants of
                #cb_context{resp_status=success, doc=[]} ->
                    crossbar_util:response_bad_identifier(AccountId, Context);
                #cb_context{resp_status=success, doc=Doc}=Context1 ->
                    Tree = whapps_json:get_value(<<"pvt_tree">>, Parent) ++ [ParentId, AccountId],
                    Updater = fun(Update, Acc) -> update_doc_tree(Tree, Update, Acc) end,
                    Updates = lists:foldr(Updater, [], Doc),
                    Context1#cb_context{doc=Updates}
            end;
        Else ->
            Else
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(update_doc_tree/3 :: (ParentTree :: list(), Update :: json_object(), Acc :: json_objects()) -> json_objects()).
update_doc_tree(ParentTree, {struct, Prop}, Acc) ->
    AccountId = props:get_value(<<"id">>, Prop),
    ParentId = lists:last(ParentTree),
    case crossbar_doc:load(AccountId, #cb_context{db_name=?AGG_DB}) of
        #cb_context{resp_status=success, doc=Doc} ->
            Tree = whapps_json:get_value(<<"pvt_tree">>, Doc),
            SubTree =
                case lists:dropwhile(fun(E)-> E =/= ParentId end, Tree) of
                    [] -> [];
                    List -> lists:nthtail(1,List)
                end,
            [whapps_json:set_value(<<"pvt_tree">>, [E || E <- ParentTree ++ SubTree, E =/= AccountId], Doc) | Acc];
        _Else ->
            Acc
    end;
update_doc_tree(_ParentTree, _Object, Acc) ->
    Acc.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function returns the private fields to be added to a new account
%% document
%% @end
%%--------------------------------------------------------------------
-spec(set_private_fields/1 :: (JObj :: json_object()) -> json_object()).
set_private_fields(JObj) ->    
    JObj1 = whapps_json:set_value(<<"pvt_type">>, <<"account">>, JObj),
    JObj2 = whapps_json:set_value(<<"pvt_tree">>, [], JObj1),
    set_api_keys(JObj2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function returns the private fields to be added to a new account
%% document
%% @end
%%--------------------------------------------------------------------
-spec(set_api_keys/1 :: (JObj :: json_object()) -> json_object()).
set_api_keys(JObj) ->
    whapps_json:set_value(<<"pvt_api_key">>, whistle_util:to_binary(whistle_util:to_hex(crypto:rand_bytes(32))), JObj).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will verify an account id is valid, and if so return
%% the name of the account database
%% @end
%%--------------------------------------------------------------------
-spec(get_db_name/1 :: (AccountId :: list(binary()) | json_object() | binary()) -> binary()).
-spec(get_db_name/2 :: (AccountId :: list(binary()) | binary() | json_object(), Encoding :: unencoded | encoded | raw) -> binary()).

get_db_name(Doc) -> get_db_name(Doc, unencoded).

get_db_name({struct, _}=Doc, Encoding) ->
    get_db_name([whapps_json:get_value(["_id"], Doc)], Encoding);
get_db_name([AccountId], Encoding) ->
    get_db_name(AccountId, Encoding);
get_db_name(AccountId, Encoding) when not is_binary(AccountId) ->
    get_db_name(whistle_util:to_binary(AccountId), Encoding);
get_db_name(<<"accounts">>, _) ->
    <<"accounts">>;
%% unencode the account db name
get_db_name(<<"account/", _/binary>>=DbName, unencoded) ->
    DbName;
get_db_name(<<"account%2F", _/binary>>=DbName, unencoded) ->
    binary:replace(DbName, <<"%2F">>, <<"/">>, [global]);
get_db_name(AccountId, unencoded) ->
    [Id1, Id2, Id3, Id4 | IdRest] = whistle_util:to_list(AccountId),
    whistle_util:to_binary(["account/", Id1, Id2, $/, Id3, Id4, $/, IdRest]);
%% encode the account db name
get_db_name(<<"account%2F", _/binary>>=DbName, encoded) ->
    DbName;
get_db_name(<<"account/", _/binary>>=DbName, encoded) ->
    binary:replace(DbName, <<"/">>, <<"%2F">>, [global]);
get_db_name(AccountId, encoded) when is_binary(AccountId) ->
    [Id1, Id2, Id3, Id4 | IdRest] = whistle_util:to_list(AccountId),
    whistle_util:to_binary(["account%2F", Id1, Id2, "%2F", Id3, Id4, "%2F", IdRest]);
%% get just the account ID from the account db name
get_db_name(<<"account%2F", AccountId/binary>>, raw) ->
    binary:replace(AccountId, <<"%2F">>, <<>>, [global]);
get_db_name(<<"account/", AccountId/binary>>, raw) ->
    binary:replace(AccountId, <<"/">>, <<>>, [global]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will attempt to load the context with the db name of
%% for this account
%% @end
%%--------------------------------------------------------------------
-spec(load_account_db/2 :: (AccountId :: list(binary()) | json_object(), #cb_context{}) -> #cb_context{}).
load_account_db(AccountId, Context)->
    DbName = get_db_name(AccountId, encoded),
    logger:format_log(info, "Account determined that db name ~p", [DbName]),
    case couch_mgr:db_exists(DbName) of
        false ->
            Context#cb_context{
                 db_name = undefined
                ,account_id = undefined
            };
        true ->
            Context#cb_context{
                db_name = DbName
               ,account_id = AccountId
            }
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will create a new account and corresponding database
%% then spawn a short initial function
%% @end
%%--------------------------------------------------------------------
-spec(create_new_account_db/1 :: (Context :: #cb_context{}) -> #cb_context{}).
create_new_account_db(#cb_context{doc=Doc}=Context) ->
    DbName = get_db_name(couch_mgr:get_uuid(), encoded),
    case couch_mgr:db_create(DbName) of
        false ->
            logger:format_log(error, "ACCOUNTS(~p): Failed to create database: ~p", [self(), DbName]),
            crossbar_util:response_db_fatal(Context);
        true ->
            logger:format_log(info, "ACCOUNTS(~p): Created DB for account id ~p", [self(), get_db_name(DbName, raw)]),
            JObj = whapps_json:set_value(<<"_id">>, get_db_name(DbName, raw), Doc),
            case crossbar_doc:save(Context#cb_context{db_name=DbName, doc=JObj}) of
                #cb_context{resp_status=success}=Context1 ->                              
                    spawn(fun() ->
                                  couch_mgr:load_doc_from_file(DbName, crossbar, ?VIEW_FILE),
                                  Responses = crossbar_bindings:map(<<"account.created">>, DbName),
                                  _ = [couch_mgr:load_doc_from_file(DbName, crossbar, File) || {true, File} <- crossbar_bindings:succeeded(Responses)],
                                  replicate_from_account(get_db_name(DbName, unencoded), ?AGG_DB, ?AGG_FILTER)
                             end),
                    Context1;
                Else ->
                    logger:format_log(info, "ACCTS(~p): Other PUT resp: ~p: ~p~n", [Else#cb_context.resp_status, Else#cb_context.doc]),
                    Else
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will determine if the realm in the request is 
%% unique or belongs to the request being made
%% @end
%%--------------------------------------------------------------------
-spec(is_unique_realm/2 :: (AccountId :: binary()|undefined, Context :: #cb_context{}) -> boolean()).            
is_unique_realm(AccountId, Context) ->
    Realm = whapps_json:get_value(<<"realm">>, Context#cb_context.req_data),
    JObj = case crossbar_doc:load_view(?AGG_GROUP_BY_REALM, [{<<"key">>, Realm}, {<<"reduce">>, <<"true">>}], Context#cb_context{db_name=?AGG_DB}) of
               #cb_context{resp_status=success, doc=[J]} -> J;
               #cb_context{resp_status=success, doc=[]} -> []
           end,    
    Assignments = whapps_json:get_value(<<"value">>, JObj, []),
    case AccountId of
        undefined ->
            Assignments =:= [];
        Id ->
            Assignments =:= [] orelse Assignments =:= [Id]
    end.
