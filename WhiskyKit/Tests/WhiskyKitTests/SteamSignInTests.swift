//
//  SteamSignInTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Testing
@testable import WhiskyKit

@Suite struct SteamSignInTests {
    @Test func signedInAfterLogOnResponse() {
        let log = """
        [2026-11-23 18:00:23] [Logged Off, 4, 0] [U:1:1172597968] LogOn() called; not connected yet
        [2026-11-23 18:00:25] [Logging On, 4, 7] [U:1:1172597968] RecvMsgClientLogOnResponse() : 'OK'
        [2026-11-23 18:00:25] [Logged On, 4, 7] [U:1:1172597968] RecvMsgClientLogOnResponse() : processing complete
        [2026-11-23 18:03:11] Adding peer server
        """
        #expect(SteamSignIn.state(logTail: log) == .signedIn)
    }

    @Test func signedOutWithNoAccount() {
        let log = """
        [2026-11-23 18:00:25] [Logged On, 4, 7] [U:1:1172597968] RecvMsgClientLogOnResponse() : processing complete
        [2026-11-24 05:55:34] Connectivity test: Starting test
        [2026-11-24 05:55:34] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )
        [2026-11-24 05:55:36] Connectivity test: result=Connected
        """
        #expect(SteamSignIn.state(logTail: log) == .signedOut)
    }

    @Test func savedAccountStillConnectingIsPending() {
        let log = "[2026-11-23 18:00:03] [Logged Off, 0, 0] [U:1:1172597968] CCMInterface::SetSteamID"
        #expect(SteamSignIn.state(logTail: log) == .pending)
        #expect(SteamSignIn.state(logTail: "") == .pending)
    }
}
