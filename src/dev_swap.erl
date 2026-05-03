%%% @doc Minimal one-sided AO-for-AR OTC swap device.
%%%
%%% Flow:
%%% 1. Operator initializes available AO liquidity and pricing.
%%% 2. Buyer reserves AO and receives required AR transfer tags.
%%% 3. Buyer submits the AR tx id.
%%% 4. Device verifies the AR L1 transfer and submits an operator-signed AO
%%%    Transfer to MU.
-module(dev_swap).
-export([info/1, init/3, reserve/3, submit/3]).
-include("include/hb.hrl").

info(_) ->
    #{ exports => [<<"init">>, <<"reserve">>, <<"submit">>] }.

init(Base, _Req, Opts) ->
    {ok, state(Base, Opts)}.

reserve(Base, Req, Opts) ->
    State = state(Base, Opts),
    with_buyer(
        Req,
        Opts,
        fun(Buyer) ->
            with_amount(
                Req,
                Opts,
                fun(AOQty) -> reserve(Buyer, AOQty, State, Req, Opts) end
            )
        end
    ).

submit(Base, Req, Opts) ->
    State = state(Base, Opts),
    with_reservation(
        State,
        Req,
        Opts,
        fun(ID, Res) ->
            with_proof(
                Req,
                Opts,
                fun(ProofID) -> submit(ID, Res, ProofID, State, Req, Opts) end
            )
        end
    ).

state(Base, Opts) ->
    Operator =
        norm(
            hb_maps:get(
                <<"operator">>,
                Base,
                hb_opts:get(operator, undefined, Opts),
                Opts
            )
        ),
    Base#{
        <<"device">> => device(Opts),
        <<"operator">> => Operator,
        <<"ar-recipient">> =>
            norm(hb_maps:get(<<"ar-recipient">>, Base, Operator, Opts)),
        <<"ao-source">> =>
            norm(hb_maps:get(<<"ao-source">>, Base, Operator, Opts)),
        <<"ao-token">> =>
            hb_maps:get(
                <<"ao-token">>,
                Base,
                hb_opts:get(ao_payment_token, Opts),
                Opts
            ),
        <<"ao-submit-url">> =>
            hb_maps:get(
                <<"ao-submit-url">>,
                Base,
                hb_opts:get(ao_submit_url, Opts),
                Opts
            ),
        <<"price">> => int(<<"price">>, Base, 1, Opts),
        <<"price-scale">> => max(1, int(<<"price-scale">>, Base, 1, Opts)),
        <<"fee-bps">> => max(0, int(<<"fee-bps">>, Base, 0, Opts)),
        <<"available-ao">> => int(<<"available-ao">>, Base, 0, Opts),
        <<"min-ar-confirmations">> =>
            int(
                <<"min-ar-confirmations">>,
                Base,
                hb_opts:get(swap_min_ar_confirmations, Opts),
                Opts
            ),
        <<"arweave-device">> =>
            hb_maps:get(
                <<"arweave-device">>,
                Base,
                hb_opts:get(swap_arweave_device, Opts),
                Opts
            ),
        <<"reservations">> => hb_maps:get(<<"reservations">>, Base, #{}, Opts),
        <<"proofs">> => hb_maps:get(<<"proofs">>, Base, #{}, Opts)
    }.

reserve(Buyer, AOQty, State, Req, Opts) ->
    Available = maps:get(<<"available-ao">>, State),
    case Available >= AOQty of
        false ->
            http_error(409, <<"Insufficient AO liquidity.">>);
        true ->
            ID = reservation_id(Req, Opts),
            Reservations = maps:get(<<"reservations">>, State),
            case maps:is_key(ID, Reservations) of
                true ->
                    http_error(409, <<"Reservation already exists.">>);
                false ->
                    Res =
                        (quote(AOQty, State, Opts))#{
                            <<"id">> => ID,
                            <<"status">> => <<"reserved">>,
                            <<"buyer">> => Buyer,
                            <<"recipient">> =>
                                norm(hb_maps:get(<<"recipient">>, Req, Buyer, Opts)),
                            <<"ar-recipient">> => maps:get(<<"ar-recipient">>, State),
                            <<"ar-tags">> => #{
                                <<"swap-device">> => device(Opts),
                                <<"swap-reservation">> => ID
                            }
                        },
                    {ok,
                        State#{
                            <<"available-ao">> => Available - AOQty,
                            <<"reservations">> => Reservations#{ ID => Res },
                            <<"last-reservation">> => Res
                        }
                    }
            end
    end.

submit(ID, Res, ProofID, State, Req, Opts) ->
    case {maps:get(<<"status">>, Res) =:= <<"reserved">>, signed_by_buyer(Res, Req, Opts)} of
        {false, _} ->
            http_error(409, <<"Reservation is not open.">>);
        {_, false} ->
            http_error(403, <<"Only the reservation buyer can submit proof.">>);
        {true, true} ->
            case maps:get(ProofID, maps:get(<<"proofs">>, State), not_found) of
                not_found -> verify_and_pay(ID, Res, ProofID, State, Opts);
                ID -> {ok, State#{ <<"last-release">> => Res }};
                _ -> http_error(409, <<"AR transfer proof already used.">>)
            end
    end.

verify_and_pay(ID, Res0, ProofID, State, Opts) ->
    case ar_tx(ProofID, State, Opts) of
        {ok, TX} ->
            case verify_ar(ID, Res0, ProofID, TX, State, Opts) of
                {ok, Res} -> pay(ID, Res, State, Opts);
                Error -> Error
            end;
        {error, #{ <<"status">> := _ } = Error} ->
            {error, Error};
        _ ->
            http_error(424, <<"Could not verify AR transfer.">>)
    end.

verify_ar(ID, Res, ProofID, TX, State, Opts) ->
    case tx_key([<<"swap-reservation">>, <<"reservation-id">>], TX, Opts) of
        not_found ->
            http_error(400, <<"AR transfer missing swap reservation tag.">>);
        RawID ->
            case norm(RawID) =:= ID of
                true -> verify_ar_device(ID, Res, ProofID, TX, State, Opts);
                false -> http_error(400, <<"AR transfer reservation tag does not match.">>)
            end
    end.

verify_ar_device(ID, Res, ProofID, TX, State, Opts) ->
    case tx_key([<<"swap-device">>], TX, Opts) of
        not_found -> verify_ar_target(ID, Res, ProofID, TX, State, Opts);
        Device ->
            case Device =:= device(Opts) of
                true -> verify_ar_target(ID, Res, ProofID, TX, State, Opts);
                false -> http_error(400, <<"AR transfer swap device tag does not match.">>)
            end
    end.

verify_ar_target(ID, Res, ProofID, TX, State, Opts) ->
    Expected = maps:get(<<"ar-recipient">>, State),
    Target = hb_maps:get(<<"target">>, TX, not_found, Opts),
    case Target =/= not_found andalso norm(Target) =:= Expected of
        false ->
            http_error(400, <<"AR transfer target does not match.">>);
        true ->
            Quantity = tx_int(<<"quantity">>, TX, Opts),
            Required = maps:get(<<"ar-total">>, Res),
            case Quantity >= Required of
                false ->
                    http_error(400, <<"AR transfer quantity is too low.">>);
                true ->
                    {ok,
                        Res#{
                            <<"status">> => <<"verified">>,
                            <<"ar-transfer-id">> => ProofID,
                            <<"ar-verified">> => true,
                            <<"ar-verification">> => #{
                                <<"tx">> => ProofID,
                                <<"target">> => norm(Target),
                                <<"quantity">> => Quantity,
                                <<"swap-reservation">> => ID
                            }
                        }
                    }
            end
    end.

pay(ID, Res, State, Opts) ->
    case signed_wallet(Opts) of
        {ok, Source, Wallet} ->
            case Source =:= maps:get(<<"ao-source">>, State) of
                true ->
                    case ao_transfer(ID, Res, Source, Wallet, State, Opts) of
                        {ok, Release} -> release(ID, Res, Release, State);
                        Error -> Error
                    end;
                false ->
                    http_error(500, <<"AO source must match the node signing wallet.">>)
            end;
        Error ->
            Error
    end.

release(ID, Res, Release, State) ->
    ProofID = maps:get(<<"ar-transfer-id">>, Res),
    Released = Res#{
        <<"status">> => <<"released">>,
        <<"released-ao-quantity">> => maps:get(<<"ao-quantity">>, Res),
        <<"ao-release">> => Release
    },
    {ok,
        State#{
            <<"reservations">> =>
                (maps:get(<<"reservations">>, State))#{ ID => Released },
            <<"proofs">> => (maps:get(<<"proofs">>, State))#{ ProofID => ID },
            <<"last-release">> => Released
        }
    }.

ao_transfer(ID, Res, Source, Wallet, State, Opts) ->
    try
        Token = maps:get(<<"ao-token">>, State),
        Recipient = maps:get(<<"recipient">>, Res),
        Quantity = hb_util:bin(maps:get(<<"ao-quantity">>, Res)),
        Tags = [
            {<<"Data-Protocol">>, <<"ao">>},
            {<<"Variant">>, <<"ao.TN.1">>},
            {<<"Type">>, <<"Message">>},
            {<<"Content-Type">>, <<"text/plain">>},
            {<<"SDK">>, <<"hyperbeam">>},
            {<<"Action">>, <<"Transfer">>},
            {<<"Recipient">>, Recipient},
            {<<"Quantity">>, Quantity},
            {<<"X-HB-Recipient">>, Recipient},
            {<<"X-HB-Swap-Reservation">>, ID},
            {<<"X-HB-AR-Transfer">>, maps:get(<<"ar-transfer-id">>, Res)}
        ],
        Item =
            ar_bundles:sign_item(
                ar_bundles:new_item(
                    hb_util:native_id(Token),
                    crypto:strong_rand_bytes(32),
                    Tags,
                    <<"hyperbeam">>
                ),
                Wallet
            ),
        true = ar_bundles:verify_item(Item),
        MessageID = hb_util:human_id(ar_bundles:id(Item, signed)),
        case post_ao(maps:get(<<"ao-submit-url">>, State), ar_bundles:serialize(Item), Opts) of
            {ok, Result} ->
                {ok, #{
                    <<"mode">> => <<"wallet">>,
                    <<"token">> => Token,
                    <<"message-id">> => MessageID,
                    <<"source">> => Source,
                    <<"recipient">> => Recipient,
                    <<"quantity">> => maps:get(<<"ao-quantity">>, Res),
                    <<"result">> => Result
                }};
            Error ->
                Error
        end
    catch
        _:_ -> http_error(500, <<"AO wallet transfer failed.">>)
    end.

post_ao(URL, Body, Opts) ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Req = {
        binary_to_list(URL),
        [{"accept", "application/json"}],
        "application/octet-stream",
        Body
    },
    HTTPOpts = [
        {connect_timeout, hb_opts:get(http_client_connect_timeout, 5000, Opts)},
        {timeout, hb_opts:get(http_client_send_timeout, 30000, Opts)}
    ],
    case httpc:request(post, Req, HTTPOpts, [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, RespBody}} when Status >= 200, Status < 300 ->
            {ok, #{ <<"status">> => Status, <<"body">> => RespBody }};
        {ok, {{_, Status, _}, _Headers, RespBody}} ->
            {error, #{
                <<"status">> => 502,
                <<"body">> => <<"AO submit endpoint rejected transfer.">>,
                <<"ao-status">> => Status,
                <<"ao-body">> => RespBody
            }};
        {error, Reason} ->
            {error, #{
                <<"status">> => 502,
                <<"body">> => <<"Unable to submit AO wallet transfer.">>,
                <<"reason">> => hb_format:term(Reason, Opts, 0)
            }}
    end.

ar_tx(ID, State, Opts) ->
    case confirmed(ID, State, Opts) of
        ok ->
            case arweave_tx(ID, State, Opts) of
                {ok, TX} -> {ok, TX};
                _ -> gateway_tx(ID, Opts)
            end;
        Error ->
            Error
    end.

arweave_tx(ID, State, Opts) ->
    try
        hb_ao:resolve(
            #{ <<"device">> => maps:get(<<"arweave-device">>, State) },
            #{ <<"path">> => <<"tx">>, <<"tx">> => ID, <<"exclude-data">> => true },
            Opts
        )
    catch
        _:_ -> {error, arweave_failed}
    end.

gateway_tx(ID, Opts) ->
    case hb_http:request(<<"GET">>, gateway(Opts), <<"/tx/", ID/binary>>, #{}, Opts) of
        {ok, #{ <<"body">> := Body }} -> tx_from_json(Body, Opts);
        {ok, Body} when is_binary(Body) -> tx_from_json(Body, Opts);
        Error -> Error
    end.

tx_from_json(Body, Opts) ->
    try
        TX = ar_tx:json_struct_to_tx(hb_json:decode(Body)),
        {ok, hb_message:convert(TX, <<"structured@1.0">>, <<"tx@1.0">>, Opts)}
    catch
        _:_ -> {error, gateway_tx_not_ready}
    end.

confirmed(ID, State, Opts) ->
    Min = maps:get(<<"min-ar-confirmations">>, State),
    case Min =< 0 of
        true ->
            ok;
        false ->
            case hb_http:request(<<"GET">>, gateway(Opts), <<"/tx/", ID/binary, "/status">>, #{}, Opts) of
                {ok, #{ <<"body">> := Body }} -> status_confirmed(Body, Min);
                {ok, Body} when is_binary(Body) -> status_confirmed(Body, Min);
                _ -> {error, #{ <<"status">> => 424, <<"body">> => <<"AR tx is not confirmed.">> }}
            end
    end.

status_confirmed(Body, Min) ->
    try
        Status = hb_json:decode(Body),
        Confirmations =
            case hb_util:safe_int(
                maps:get(
                    <<"number_of_confirmations">>,
                    Status,
                    maps:get(<<"confirmations">>, Status, 0)
                )
            ) of
                {ok, Int} -> Int;
                {error, _} -> 0
            end,
        case Confirmations >= Min of
            true -> ok;
            false -> {error, #{ <<"status">> => 424, <<"body">> => <<"AR tx is not confirmed.">> }}
        end
    catch
        _:_ -> {error, #{ <<"status">> => 424, <<"body">> => <<"AR tx is not confirmed.">> }}
    end.

tx_key([], _TX, _Opts) ->
    not_found;
tx_key([Key | Rest], TX, Opts) ->
    case hb_maps:get(Key, TX, not_found, Opts) of
        not_found -> tx_key(Rest, TX, Opts);
        Value -> Value
    end.

tx_int(Key, TX, Opts) ->
    case hb_util:safe_int(hb_maps:get(Key, TX, 0, Opts)) of
        {ok, Int} -> Int;
        {error, _} -> 0
    end.

quote(AOQty, State, Opts) ->
    Price = maps:get(<<"price">>, State),
    Scale = maps:get(<<"price-scale">>, State),
    FeeBPS = maps:get(<<"fee-bps">>, State),
    ARQty = ceil(AOQty * Price, Scale),
    Fee = ceil(ARQty * FeeBPS, hb_util:int(hb_opts:get(swap_bps, Opts))),
    #{
        <<"ao-quantity">> => AOQty,
        <<"ar-quantity">> => ARQty,
        <<"fee">> => Fee,
        <<"ar-total">> => ARQty + Fee,
        <<"price">> => Price,
        <<"price-scale">> => Scale,
        <<"fee-bps">> => FeeBPS
    }.

with_buyer(Req, Opts, Fun) ->
    case signers(Req, Opts) of
        [Buyer] -> Fun(Buyer);
        [] -> http_error(401, <<"Reservation requests must be signed.">>);
        _ -> http_error(400, <<"Only one signer is supported.">>)
    end.

with_amount(Req, Opts, Fun) ->
    case
        hb_ao:get_first(
            [{Req, <<"ao-quantity">>}, {Req, <<"quantity">>}, {Req, <<"amount">>}],
            not_found,
            Opts
        )
    of
        not_found ->
            http_error(400, <<"Missing positive amount.">>);
        Value ->
            case hb_util:safe_int(Value) of
                {ok, Int} when Int > 0 -> Fun(Int);
                {ok, _} -> http_error(400, <<"Amount must be positive.">>);
                {error, _} -> http_error(400, <<"Amount must be an integer.">>)
            end
    end.

with_proof(Req, Opts, Fun) ->
    case
        hb_ao:get_first(
            [{Req, <<"ar-transfer-id">>}, {Req, <<"proof-id">>}, {Req, <<"tx-id">>}],
            not_found,
            Opts
        )
    of
        not_found -> http_error(400, <<"Missing AR transfer proof ID.">>);
        ProofID -> Fun(norm(ProofID))
    end.

with_reservation(State, Req, Opts, Fun) ->
    case hb_maps:get(<<"reservation-id">>, Req, not_found, Opts) of
        not_found ->
            http_error(400, <<"Missing reservation ID.">>);
        RawID ->
            ID = norm(RawID),
            case maps:get(ID, maps:get(<<"reservations">>, State), not_found) of
                not_found -> http_error(404, <<"Reservation not found.">>);
                Res -> Fun(ID, Res)
            end
    end.

signed_by_buyer(Res, Req, Opts) ->
    lists:member(maps:get(<<"buyer">>, Res), signers(Req, Opts)).

signers(Req, Opts) ->
    lists:map(fun norm/1, hb_message:signers(Req, Opts)).

signed_wallet(Opts) ->
    try
        Wallet =
            case hb_opts:get(priv_wallet, not_found, Opts) of
                not_found ->
                    hb:wallet(
                        hb_opts:get(priv_key_location, <<"hyperbeam-key.json">>, Opts)
                    );
                FoundWallet ->
                    FoundWallet
            end,
        {ok, norm(ar_wallet:to_address(Wallet)), Wallet}
    catch
        _:_ -> http_error(500, <<"AO release wallet unavailable.">>)
    end.

reservation_id(Req, Opts) ->
    norm(hb_maps:get(<<"reservation-id">>, Req, safe_id(Req, Opts), Opts)).

safe_id(Req, Opts) ->
    try hb_message:id(Req, all, Opts)
    catch _:_ -> crypto:hash(sha256, term_to_binary(Req))
    end.

device(Opts) ->
    hb_opts:get(swap_device, Opts).

gateway(Opts) ->
    hb_opts:get(gateway, <<"https://arweave.net">>, Opts).

int(Key, Msg, Default, Opts) ->
    case hb_util:safe_int(hb_maps:get(Key, Msg, Default, Opts)) of
        {ok, Int} -> Int;
        {error, _} -> Default
    end.

ceil(N, D) when D > 0 ->
    (N + D - 1) div D.

norm(undefined) -> undefined;
norm(not_found) -> undefined;
norm(Value) ->
    try hb_util:human_id(Value)
    catch
        _:_ ->
            try hb_util:bin(Value)
            catch _:_ -> Value
            end
    end.

http_error(Status, Body) ->
    {error, #{ <<"status">> => Status, <<"body">> => Body }}.
