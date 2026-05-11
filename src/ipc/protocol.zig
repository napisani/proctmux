pub const command_codec = @import("command_codec.zig");
pub const state_codec = @import("state_codec.zig");

pub const Command = command_codec.Command;
pub const Response = command_codec.Response;
pub const CommandRequest = command_codec.CommandRequest;
pub const ProcessListItem = command_codec.ProcessListItem;

pub const StateUpdate = state_codec.StateUpdate;

pub const commandName = command_codec.commandName;
pub const commandFromName = command_codec.commandFromName;
pub const commandRequestLine = command_codec.commandRequestLine;
pub const parseCommandRequestLine = command_codec.parseCommandRequestLine;
pub const responseLine = command_codec.responseLine;
pub const parseResponseLine = command_codec.parseResponseLine;

pub const stateLine = state_codec.stateLine;
pub const parseStateLine = state_codec.parseStateLine;

test {
    _ = command_codec;
    _ = state_codec;
}
