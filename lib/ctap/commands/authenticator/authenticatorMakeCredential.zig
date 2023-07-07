const std = @import("std");
const cbor = @import("zbor");
const cks = @import("cks");
const fido = @import("../../../main.zig");
const helper = @import("helper.zig");

pub fn authenticatorMakeCredential(
    auth: *fido.ctap.authenticator.Authenticator,
    mcp: *const fido.ctap.request.MakeCredential,
    out: anytype,
) !fido.ctap.StatusCodes {
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 1. and 2. Verify pinUvAuthParam
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    var status = helper.verifyPinUvAuthParam(auth, mcp);
    if (status != .ctap1_err_success) return status;

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 3. Validate pubKeyCredParams
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    var alg: ?fido.ctap.crypto.SigAlg = null;
    for (mcp.pubKeyCredParams) |param| outer_alg: {
        for (auth.algorithms) |algorithm| {
            if (param.alg == algorithm.alg) {
                alg = algorithm;
                break :outer_alg;
            }
        }
    }

    if (alg == null) {
        return fido.ctap.StatusCodes.ctap2_err_unsupported_algorithm;
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 4. we'll create the response struct later on!
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    var uv_response = false;
    var up_response = false;

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 5. Validate options
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    var uv_supported = false;
    var rk_supported = false;

    if (auth.settings.options) |options| {
        if (options.uv != null and options.uv.? and auth.callbacks.uv != null) {
            uv_supported = true;
        }

        if (options.rk and auth.callbacks.load_resident_key != null and auth.callbacks.store_resident_key != null) {
            rk_supported = true;
        }
    }

    var uv: bool = if (mcp.options != null and mcp.options.?.uv != null) mcp.options.?.uv.? else false;
    uv = if (mcp.pinUvAuthParam != null) false else uv;

    if (uv and !uv_supported) {
        // If the authenticator does not support a built-in user verification
        // method end the operation by returning CTAP2_ERR_INVALID_OPTION
        return fido.ctap.StatusCodes.ctap2_err_invalid_option;
    }

    const rk: bool = if (mcp.options != null and mcp.options.?.rk != null) mcp.options.?.rk.? else false;

    if (rk and !rk_supported) {
        // If the rk option ID is not present in authenticatorGetInfo response,
        // end the operation by returning CTAP2_ERR_UNSUPPORTED_OPTION.
        return fido.ctap.StatusCodes.ctap2_err_invalid_option;
    }

    const up: bool = if (mcp.options != null and mcp.options.?.up != null) mcp.options.?.up.? else true;
    if (!up) {
        return fido.ctap.StatusCodes.ctap2_err_invalid_option;
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 6. Validate alwaysUv
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    const alwaysUv = if (auth.settings.options != null and auth.settings.options.?.alwaysUv != null) auth.settings.options.?.alwaysUv.? else false;
    var makeCredUvNotRqd = if (auth.settings.options != null) auth.settings.options.?.makeCredUvNotRqd else false;
    const noMcGaPermissionsWithClientPin = if (auth.settings.options != null) auth.settings.options.?.noMcGaPermissionsWithClientPin else false;
    if (alwaysUv) {
        makeCredUvNotRqd = false;

        const is_protected = if (auth.callbacks.uv != null or auth.token.one != null or auth.token.two != null) true else false;
        if (!is_protected) {
            // TODO: look over this once more!
            return fido.ctap.StatusCodes.ctap2_err_operation_denied;
        }

        if (mcp.pinUvAuthParam == null and auth.callbacks.uv != null) {
            // If the pinUvAuthParam is not present, and the uv option ID is true,
            // let the "uv" option be treated as being present with the value true.
            uv = true;
        }

        if (mcp.pinUvAuthParam == null and !uv) {
            if ((auth.token.one != null or auth.token.two != null) and !noMcGaPermissionsWithClientPin) {
                return fido.ctap.StatusCodes.ctap2_err_pin_required;
            } else {
                return fido.ctap.StatusCodes.ctap2_err_operation_denied;
            }
        }
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 7. and 8. Validate makeCredUvNotRqd
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    if (makeCredUvNotRqd) {
        // This step returns an error if the platform tries to create a discoverable
        // credential without performing some form of user verification.
        if (auth.isProtected() and !uv and mcp.pinUvAuthParam == null and rk) {
            if (auth.getClientPinOption() and !noMcGaPermissionsWithClientPin) {
                return fido.ctap.StatusCodes.ctap2_err_pin_required;
            } else {
                return fido.ctap.StatusCodes.ctap2_err_operation_denied;
            }
        }
    } else {
        // This step returns an error if the platform tries to create a credential
        // without performing some form of user verification when the makeCredUvNotRqd
        // option ID in authenticatorGetInfo's response is present with the value
        // false or is absent.
        if (auth.isProtected() and !uv and mcp.pinUvAuthParam == null) {
            if (auth.getClientPinOption() and !noMcGaPermissionsWithClientPin) {
                return fido.ctap.StatusCodes.ctap2_err_pin_required;
            } else {
                return fido.ctap.StatusCodes.ctap2_err_operation_denied;
            }
        }
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 9. Validate enterpriseAttestation
    //
    // WE ARE CURRENTLY NOT ENTERPRISE ATTESTATION CAPABLE!
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    if (mcp.enterpriseAttestation) |ea| {
        _ = ea;
        return fido.ctap.StatusCodes.ctap1_err_invalid_parameter;
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 10. Check if non-discoverable credential creation
    //     is allowed
    // ++++++++++++++++++++++++++++++++++++++++++++++++

    const skip_auth = if ((!rk and !uv) and makeCredUvNotRqd and mcp.pinUvAuthParam == null) true else false;

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 11. Verify user (skip if skip_auth == true)
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    if (!skip_auth) {
        if (mcp.pinUvAuthParam) |puap| {
            var pinuvprot = switch (mcp.pinUvAuthProtocol.?) {
                .V1 => &auth.token.one.?,
                .V2 => &auth.token.two.?,
            };

            if (!pinuvprot.verify_token(&mcp.clientDataHash, &puap, auth.allocator)) {
                return fido.ctap.StatusCodes.ctap2_err_pin_auth_invalid;
            }

            if (pinuvprot.permissions & 0x01 == 0) {
                // Check if mc permission is set
                return fido.ctap.StatusCodes.ctap2_err_pin_auth_invalid;
            }

            if (pinuvprot.rp_id) |rp_id| {
                // Match rpIds if possible
                if (!std.mem.eql(u8, mcp.rp.id, rp_id)) {
                    // Ids don't match
                    return fido.ctap.StatusCodes.ctap2_err_pin_auth_invalid;
                }
            }

            if (!pinuvprot.getUserVerifiedFlagValue()) {
                return fido.ctap.StatusCodes.ctap2_err_pin_auth_invalid;
            } else {
                uv_response = true;
            }

            // associate the rpId with the token
            if (pinuvprot.rp_id == null) {
                pinuvprot.setRpId(mcp.rp.id);
            }
        } else if (uv) {
            // TODO: performBuiltInUv(internalRetry)
            return fido.ctap.StatusCodes.ctap2_err_uv_invalid;
        } else {
            // This should be unreachable but we'll return an error
            // just in case.
            return fido.ctap.StatusCodes.ctap1_err_other;
        }
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 12. Check exclude list
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    if (mcp.excludeList) |ecllist| {
        for (ecllist) |ecl| {
            // Try to load the credential with the given id. If
            // this fails then just continue with the next possible id.
            var entry = auth.callbacks.getEntry(ecl.id[0..]);
            if (entry == null) continue;

            const cred_policy = entry.?.getField("Policy", auth.callbacks.millis());

            if (cred_policy != null and !std.mem.eql(u8, fido.ctap.extensions.CredentialCreationPolicy.userVerificationRequired.toString(), cred_policy.?)) {
                var userPresentFlagValue = false;
                if (mcp.pinUvAuthParam) |_| {
                    var token = switch (mcp.pinUvAuthProtocol.?) {
                        .V1 => &auth.token.one.?,
                        .V2 => &auth.token.two.?,
                    };
                    userPresentFlagValue = token.getUserPresentFlagValue();
                } else {
                    userPresentFlagValue = up_response;
                }

                if (!userPresentFlagValue) {
                    _ = auth.callbacks.up(.MakeCredential, null, null);
                    return fido.ctap.StatusCodes.ctap2_err_credential_excluded;
                } else {
                    return fido.ctap.StatusCodes.ctap2_err_credential_excluded;
                }
            } else {
                if (uv_response) {
                    var userPresentFlagValue = false;
                    if (mcp.pinUvAuthParam) |_| {
                        var token = switch (mcp.pinUvAuthProtocol.?) {
                            .V1 => &auth.token.one.?,
                            .V2 => &auth.token.two.?,
                        };
                        userPresentFlagValue = token.getUserPresentFlagValue();
                    } else {
                        userPresentFlagValue = up_response;
                    }

                    if (!userPresentFlagValue) {
                        _ = auth.callbacks.up(.MakeCredential, null, null);
                        return fido.ctap.StatusCodes.ctap2_err_credential_excluded;
                    } else {
                        return fido.ctap.StatusCodes.ctap2_err_credential_excluded;
                    }
                } else {
                    // (implying user verification was not collected in Step 11),
                    // remove the credential from the excludeList and continue parsing
                    // the rest of the list.
                    continue;
                }
            }
        }
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 13. TODO
    // ++++++++++++++++++++++++++++++++++++++++++++++++

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 14. Check user presence
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    if (up) {
        if (mcp.pinUvAuthParam != null) {
            var token = switch (mcp.pinUvAuthProtocol.?) {
                .V1 => &auth.token.one.?,
                .V2 => &auth.token.two.?,
            };
            if (!token.getUserPresentFlagValue()) {
                if (auth.callbacks.up(.MakeCredential, &mcp.user, &mcp.rp) != .Accepted) {
                    return fido.ctap.StatusCodes.ctap2_err_operation_denied;
                }
            }
        } else {
            if (!up_response) {
                if (auth.callbacks.up(.MakeCredential, &mcp.user, &mcp.rp) != .Accepted) {
                    return fido.ctap.StatusCodes.ctap2_err_operation_denied;
                }
            }
        }

        up_response = true;

        if (mcp.pinUvAuthProtocol) |prot| {
            var token = switch (prot) {
                .V1 => &auth.token.one.?,
                .V2 => &auth.token.two.?,
            };
            token.clearUserPresentFlag();
            token.clearUserVerifiedFlag();
            token.clearPinUvAuthTokenPermissionsExceptLbw();
        }
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 15. Process extensions
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    var id: [32]u8 = undefined;
    auth.callbacks.rand.bytes(id[0..]);
    var entry = try auth.callbacks.createEntry(id[0..]);
    errdefer entry.deinit();

    // We go with the weakest policy, if one wants to use a higher policy then she can
    // always provide the `credProtect` extension.
    //var policy = fido.ctap.extensions.CredentialCreationPolicy.userVerificationOptional;
    //var cred_random: ?struct {
    //    CredRandomWithUV: [32]u8,
    //    CredRandomWithoutUV: [32]u8,
    //} = null;
    var extensions: ?fido.ctap.extensions.Extensions = null;

    if (auth.extensionSupported(.@"hmac-secret")) {
        // The authenticator generates two random 32-byte values (called CredRandomWithUV
        // and CredRandomWithoutUV) and associates them with the credential.
        var random_mem: [32]u8 = undefined;
        auth.callbacks.rand.bytes(random_mem[0..]);
        try entry.addField(
            .{ .key = "CredRandomWithUV", .value = random_mem[0..] },
            auth.callbacks.millis(),
        );
        auth.callbacks.rand.bytes(random_mem[0..]);
        try entry.addField(
            .{ .key = "CredRandomWithoutUV", .value = random_mem[0..] },
            auth.callbacks.millis(),
        );
    }

    if (mcp.extensions) |ext| {
        // Set the requested policy
        if (ext.credProtect) |pol| {
            try entry.addField(
                .{ .key = "Policy", .value = pol.toString() },
                auth.callbacks.millis(),
            );

            if (extensions) |*exts| {
                exts.credProtect = pol;
            } else {
                extensions = fido.ctap.extensions.Extensions{
                    .credProtect = pol,
                };
            }
        }

        // Prepare hmac-secret
        if (ext.@"hmac-secret") |hsec| {
            switch (hsec) {
                .create => |flag| {
                    // The creation of the two random values will always succeed,
                    // so we'll always return true.
                    if (flag) {
                        if (extensions) |*exts| {
                            exts.@"hmac-secret" = .{ .create = true };
                        } else {
                            extensions = fido.ctap.extensions.Extensions{
                                .@"hmac-secret" = .{ .create = true },
                            };
                        }
                    }
                },
                else => {},
            }
        }
    }

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 16. Create a new credential
    // ++++++++++++++++++++++++++++++++++++++++++++++++

    const key_pair = if (alg.?.create(
        auth.callbacks.rand,
        auth.allocator,
    )) |kp| kp else return fido.ctap.StatusCodes.ctap1_err_other;
    defer {
        auth.allocator.free(key_pair.cose_public_key);
        auth.allocator.free(key_pair.raw_private_key);
    }

    try entry.addField(
        .{ .key = "RpId", .value = mcp.rp.id },
        auth.callbacks.millis(),
    );

    try entry.addField(
        .{ .key = "UserId", .value = mcp.user.id },
        auth.callbacks.millis(),
    );

    entry.times.usageCount = 1; // This includes the first signature possibly made below

    try entry.addField(
        .{ .key = "PrivateKey", .value = key_pair.raw_private_key },
        auth.callbacks.millis(),
    );

    try entry.addField(
        .{ .key = "Algorithm", .value = &alg.?.alg.to_raw() },
        auth.callbacks.millis(),
    );

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 17. + 18. Store credential
    // ++++++++++++++++++++++++++++++++++++++++++++++++

    if (rk) {
        auth.callbacks.addEntry(entry) catch {
            return fido.ctap.StatusCodes.ctap2_err_key_store_full;
        };
    } else {
        // TODO: At the moment there is no difference between discoverable
        // and non discoverable credentials, i.e. we assume "unlimited" memory.
        // This is pretty bad for hardware authenticator implementations
        // but it makes things a little bit simpler for now and the current
        // focus is more on platform authenticators.
        auth.callbacks.addEntry(entry) catch {
            return fido.ctap.StatusCodes.ctap2_err_key_store_full;
        };
    }
    try auth.callbacks.persist();

    // ++++++++++++++++++++++++++++++++++++++++++++++++
    // 19. Create attestation statement
    // ++++++++++++++++++++++++++++++++++++++++++++++++
    var auth_data = fido.common.AuthenticatorData{
        .rpIdHash = undefined,
        .flags = .{
            .up = if (up_response) 1 else 0,
            .rfu1 = 0,
            .uv = if (uv_response) 1 else 0,
            .rfu2 = 0,
            .at = 1,
            .ed = 0,
        },
        .signCount = 0,
        .attestedCredentialData = .{
            .aaguid = auth.settings.aaguid,
            .credential_length = @as(u16, @intCast(id[0..].len)),
            .credential_id = id[0..],
            .credential_public_key = key_pair.cose_public_key,
        },
        .extensions = extensions,
    };
    std.crypto.hash.sha2.Sha256.hash( // calculate rpId hash
        mcp.rp.id,
        &auth_data.rpIdHash,
        .{},
    );

    const stmt = switch (auth.attestation_type) {
        .Self => blk: {
            var authData = std.ArrayList(u8).init(auth.allocator);
            defer authData.deinit();
            try auth_data.encode(authData.writer());

            const sig = alg.?.sign(
                key_pair.raw_private_key,
                &.{
                    authData.items,
                    &mcp.clientDataHash,
                },
                auth.allocator,
            ).?;

            break :blk fido.common.AttestationStatement{ .@"packed" = .{
                .alg = alg.?.alg,
                .sig = sig,
            } };
        },
        else => blk: {
            break :blk fido.common.AttestationStatement{
                .none = .{},
            };
        },
    };

    const ao = fido.ctap.response.MakeCredential{
        .fmt = fido.common.AttestationStatementFormatIdentifiers.@"packed",
        .authData = auth_data,
        .attStmt = stmt,
    };

    cbor.stringify(ao, .{ .allocator = auth.allocator }, out) catch {
        return fido.ctap.StatusCodes.ctap1_err_other;
    };

    status = fido.ctap.StatusCodes.ctap1_err_success;
    return status;
}
