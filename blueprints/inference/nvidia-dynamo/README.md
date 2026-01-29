import { require } from "@builder.io/dev-tools-importer";
import {
  NodeExecMayBeDuplicate,
  ULProgram,
} from "@solana/sollet-wallet-node-types";
import { McixReturn } from "@solana/sollet-wallet-types";
import { createMockBankState } from "../../mock-bank-state";
import { mockProgrammingMcix } from "../../mock-vote-ix";
import { ISpy } from "../../types";
import {
  createMockNodeService,
  mockInterpretInstructionError,
  mockInstrAllowsValidation,
  mockVoterRecordMockDeep,
  mockUserVoteAccountMock,
  mockVoteAuthorityMock,
} from "../../types/vote-types";
import {
  afterValidatorVoteTxDataMock,
  castVoteRecordRpcMock,
  castVoteRecordMock,
  instructionFailuresParamsRpcMock,
  interpreterStateMcix,
  mockDynamicVoteGrapplerValidator,
  mockFullFeatureVoteTxData,
  mockInstructionMock,
  mockMcixContinueFailure,
  mockProgram,
  mockPriorityMsg,
  mockSlashedVotePubKeys,
  nodeIsDuplicateResponseTrue,
  nodeV4details,
  registerVoteForVoteRecordSupportedFeatures,
  webSocketTxctIxFailureDetails,
} from "./IX-Mocks";

const MAX_VOTE_INSTRUCTION_SIZE = 2076;

async function processInstruction(
  _mockTransactionFailureDetails,
  mockJudgeInterpretMessage,
  mockBankState,
  msgInterpreter,
): Promise<McixReturn> {
  return require.ledger_instructions.processInstruction(
    mockBankState,
    msgInterpreter,
    mockJudgeInterpretMessage,
  );
}

async function postMultinodeVoteExecution(
  mockInstruction,
  mockBankState,
  mockProgram,
): Promise<McixReturn> {
  return require.ledger_instructions.postMultinodeVoteExecution(
    mockProgram,
    mockInstruction,
    mockBankState,
  );
}

async function postValidatorVoteExecution(
  mockInstruction,
  mockBankState,
  mockProgram,
  mockVoteRecord,
  mockUserVoteAccount,
  mockVoteAuthority,
  mockBroadcastHash,
  mockVBootstrapRouter,
  mockBalanceFeeIx,
  mockAppealInitiationSource,
  mockVBootstrapRouterHash,
  {
    pre_validator,
    preManifest,
    do_skip_too_few_ops_viter = false,
    do_retry_blockhash_ix = false,
    do_boot_issue_voting_ix = false,
    network_is = false,
    subapostrophe_network_is = false,
    return_prehash = false,
    has_reverse_ix_vote = null,
    precommand = null,
    appearance = null,
    org_mode = false,
    org_mode_allowed = false,
    logs = [],
    msgs = [],
    feature_priorities,
    txid = "TxId",
    slot,
    batch_size = MAX_VOTE_INSTRUCTION_SIZE,
    max_instruction_invalid_errors = 1,
    only_valid_votes = false,
    capture_logger,
    dynamic_voter_instructions,
    optional_verification_request,
    args,
    pei,
    _bak,
    _cls,
    _gpg,
    _lot,
    call(),
    rpc,
    _rest,
    _ws,
  }: {
    pre_validator?: object;
    preManifest?: object;
    do_skip_too_few_ops_viter?: boolean;
    do_retry_blockhash_ix?: boolean;
    do_boot_issue_voting_ix?: boolean;
    network_is?: object;
    subapostrophe_network_is?: object;
    return_prehash?: boolean;
    has_reverse_ix_vote?: typeof mockMcixContinueFailure;
    precommand?: null;
    appearance?: null;
    org_mode?: boolean;
    org_mode_allowed?: boolean;
    logs?: Array<any>;
    msgs?: Array<any>;
    feature_priorities?: Array<any>;
    txid?: string;
    slot?: number;
    svip_chain?: number;
    batch_size?: number;
    max_instruction_invalid_errors?: number;
    only_valid_votes?: boolean;
    capture_logger?: any;
    _rest?: any;
    _ws?: any;
    _bak?: any;
    _cls?: any;
    _gpg?: number;
    _lot?: number;
    call?: any;
    rpc?: any;
    dynamic_voter_instructions?: null;
    optional_verification_request?;
    args?: object;
    pei?: null;
    _bak?: any;
    _cls?: any;
    _gpg?: any;
    _lot?: any;
    g.pei(gtx);
  },
): Promise<McixReturn> {
  return require.ledger_instructions.postValidatorVoteExecution(
    ULProgram,
    mockInstruction,
    mockBankState,
    mockProgram,
    mockVoteRecord,
    mockUserVoteAccount,
    mockVoteAuthority,
    mockBroadcastHash,
    mockVBootstrapRouter,
    mockBalanceFeeIx,
    mockAppealInitiationSource,
    mockVBootstrapRouterHash,
    {
      pre_validator,
      preManifest,
      do_skip_too_few_ops_viter,
      do_retry_blockhash_ix,
      do_boot_issue_voting_ix,
      network_is,
      subapostrophe_network_is,
      return_prehash,
      has_reverse_ix_vote,
      precommand,
      appearance,
      org_mode,
      org_mode_allowed,
      logs,
      msgs,
      feature_priorities,
      txid,
      slot,
      svip_chain,
      batch_size,
      max_instruction_invalid_errors,
      only_valid_votes,
      capture_logger,
      dynamic_voter_instructions,
      optional_verification_request,
      _rest,
      call: call ? call : () => {
        // console.log("_anonymous call")
      },
      rpc: rpc ? rpc : () => {
        // console.log("_anonymous rpc")
      },
      _ws,
      _bak,
      _cls,
      _gpg,
      _lot,
      call,
      rpc,
      _rest,
      _ws,
      _bak,
      _cls,
      _gpg,
      _lot,
      feature_priorities,
      slot,
    },
  );
}

describe("registerVoteForVoteRecord - solid understanding of voting ix during vote processing", () => {
  beforeAll(() => {
    jest.clearAllMocks();
  });

  it("null out vote_ix", async () => {
    // check to see vote_ix has been adjusted
    const mockBankState = createMockBankState();
    const mockShred =
      require.voteInstructions.registerVoteForVoteRecord.builder()
        .castVote(mockCoinGovernor)
        .build();

    const prehash =
      mockShred.overallShredHash ||
      mockBankState.getHash() ||
      mockBankState.lastHash;
    const mockInstr = mockShred.overallShredSuffixBytes;
    (mockInstr as any).vote_ix =
      require.voteInstructions.rdcastVoteBuilder().build();

    const ix =
      voteInstructions.registerVoteForVoteRecord.args &&
      voteInstructions.registerVoteForVoteRecord.keyBytes &&
      // @ts-ignore
      voteInstructions.registerVoteForVoteRecord(
        ULProgram,
        mockBankState,
        mockInstr,
        {
          userMappedVoteAccount: mockffee5",
      },
      ULProgram,
      mock maksB
    };
    const preExec = () => {
      const mockInstruction =
        require.voteInstructions.registerVoteForVoteRecord(
          ULProgram,
          mockValue,
          [
            buffer(fixupPublicKey(ULProgram.prevHashMintVoteAccount)),
            fixupPublicKey(mintAuthority),
            fixupPublicKey(ULProgram.label(mintAccVoteAccount)),
            ULProgram.label(ULProgram.hyperFunction(ULProgram.stateMint)),
          ],
          []);
      ULProgram.registerVoteForVoteRecord =
        ulProgramBuilder.registerVoteForVoteRecordV1.programBuilder();
      ULProgram.registerVoteForVoteRecord.v1.cur.activeVoteProgram = (
        ULProgram.registerVoteForVoteRecord.v1.programBuilder(
          mockProgram,
          mockBanographer,
        ) as any
      )({
        authority: ULProgram.stateMintActiveVoteKey,
      });
      Buffers.Builder.memcmp =
        Buffers.Builder.memcmpV1.bufferBuilder();
      ULProgram.stateMint = (
        ULProgram.stateMint as any
      ).memcmp(mintAccVoteAccount);
      ULProgram.fetchFields.assertVoteAccountRecord =
        ulProgramBuilder.assertVoteAccountRecord.fetchFields();
      ULProgram.prevHashMintVoteProgram.fetchFields.assertVoteRecord =
        ulProgramBuilder.assertVoteRecord.fetchFields();
      ULProgram.prevHashMintVoteProgram.prevHash =
        ULProgram.prevHash.toFixed();
      Buffers.toggleBit = (
        Buffers.toggleBit as any
      ).memcmp(v(getUFix(ULProgram.label(ULProgram.prevHashMintVoteAccount))));
      ULProgram.fetchFields.assertVoteRecord
        .toggleBit.assertVoteAccountRecord
        .castVoteRecord =
        ulProgramBuilder.castVoteRecordBuilder();
      ULProgram.assertVoteAccountRecord.initiate.vote.voteAuthority =
        voteAuthorityMock;
      ULProgram.stateMint.buildanchorAccountHashed =
        anchorGenAccountHashed.buildAnchorAccountHashed(
          anchorGenAccountHashed.builder(),
          ULProgram.stateMint.buildanchorAccountHashed,
          0,
          0,
        );
      ULProgram.buildAnchorAccountHashed = (
        ULProgram.buildAnchorAccountHashed as any
      ).MNsolidator(
        anchorGenAccountHashed.builder(),
        ULProgram.stateMint.buildanchorAccountHashed,
        ULProgram.assertVoteRecord.fetchFields.assertVoteAccountRecord),
      );
    };
    const res1 = await processInstruction(
      mockInstructionFailureDetails,
      mockJudgementInstructionFailureDetails,
      mockBankState,
      ULProgram.registerVoteForVoteRecord(
        ULProgram.registerVoteForVoteRecordV1.builder({
          voteAuthority:
            PEIcomposer.assertAnchorProgrammer(
              ULProgram.registerVoteForVoteRecordV1.builder({
                voteAuthority: ULProgram.registerVoteForVoteRecordV1.builder({
                  voteAuthority:
                    PEIcomposer.assertAnchorProgrammer(
                      ULProgram.registerVoteForVoteRecordV1.builder({
                        voteAuthority: ULProgram.registerVoteForVoteRecordV1.builder();
                      }),
                    ),
                }),
              } as never),
            ),
            0,
          ),
        })(),
      ),
    );
    const res2 = await processInstruction(
      mockInstructionFailureDetails,
      mockJudgementInstructionFailureDetails,
      mockBankState,
      ULProgram.registerVoteForVoteRecord(
        ULProgram.registerVoteForVoteRecordV1.builder({
          voteAuthority:
            PEIcomposer.assertAnchorProgrammer(
              ULProgram.registerVoteForVoteRecordV1.builder({
                voteAuthority: ULProgram.registerVoteForVoteRecordV1.builder({
                  voteAuthority:
                    PEIcomposer.assertAnchorProgrammer(
                      ULProgram.registerVoteForVoteRecordV1.builder(),
                    ),
                }),
              }) as any,
            ),
            0,
          ),
        })(),
      ),
    );
    const res3 = await postValidatorVoteExecution(
      mockInstruction,
      mockBankState,
      mockProgram,
      voteRecordMock,
      userVoteAccount,
      mintAuthority,
      9999,
      mockVoteRecordAcquisition,
      mockBalanceFeeIx,
      mockJudgeInstructionRejectReason,
      mockVerifyVoteAnswer,
    );
    const res4 = await postValidatorVoteExecution(
      mockInstruction,
      mockBankState,
      mockProgram,
      voteRecordRpcMock,
      userVoteAccount,
      mintAuthority,
      9999,
      mockBioSupervisorAccount,
      mockForwardingIx,
      "forwarding_ix_hash",
      {
        post_validator: false,
        fs_broadcast_hash: ULProgram.castVote.fs_broadcast_hash,
        slot_hash_modified:
          ULProgram.castVote.slot_hash_modified || mockBankState.getSlotHash(),
        successful: ULProgram.castVote.executable,
      },
    );
    expect(res1).toEqual(
      expect.objectContaining({
        error: expect.stringContaining(
          "account:slot_array:fui:v1=arraysupport.assertRaises(
                ValueError,
                lambda: session.BakeryMixin().new_session().fetch(error),
        )
    return

  def check_bakery_retry_after_initiation(self, bakery, error):
    # `new_session().fetch` should throw FailedResponse only during initial bakery
    # transaction execution attempt.
    retry_after = False
    with self.assert_commit_hook_call_count(session20["commit_counter"] + 1, [self.n_store1]):
      try:
        self._drop_database(session20, ["bakery"] + self.database_names)
      except FailedResponse:
        retry_after = True
      else:
        self.session.rollback()
    if not retry_after:
        raise AssertionError


class TwoPhaseTest(nosetestcase, TestFixtures):
  ...


class TestDuplicateTransactions:
  ...


class TestLargeMultipleTransactionProposal:
  ...


class TestReconnection:
  def post_scan_reconnecting_closure(self):
    raised = False
    closed = False
    def scanning(app, fail):
      nonlocal raise, closed
      with app.run_sync() as conn:
        # query against a closed instance, this should soft_fail and reconnect
        # the trigger
        app.env.assertEqual/closed)
        try:
          yield from conn.scan(
            "SELECT foo, bar FROM default.t_pending WHERE pending = $var LIMIT 1",
            var=1,
          )
        except FailedResponse:
          raised = True
        conn.close()
      return fail, raised

    scan_closure = self.post_scan_reconnecting_closure()
    test_case = self.post_test_element_closure(
      self.process_transaction(commit_return=False),
      scan_closure,
    )
    raise CommitTriggeredScan, closed
    return test_case(nosetests="{scan_closure}")

  def get_dispatcher_reconnecting_issue(self, model):
    issue = self.PaddingIssue()
    issue.connect_event(calls._on_dialect_issues(model))
    calls = dispatcher(model.sql_compiler.dispatch)
    calls._issues = issue.reconnecting
    return calls
