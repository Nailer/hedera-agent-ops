// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentRegistry
 * @notice Identity and spend policy for agents. The registry answers two questions the router asks
 *         before every action: *is this caller allowed to act as this agent*, and *is this agent
 *         still within its budget*.
 *
 * @dev **Three roles, deliberately separated.**
 *
 * - `controller` — a human or multisig. Sets policy, rotates the operator, can deactivate.
 * - `operator` — the agent's hot key. May submit actions and nothing else.
 * - `treasury` — where the agent's funds live and where output is delivered.
 *
 * An autonomous agent needs a key that signs without a human present, and that key will eventually
 * leak. Keeping policy changes off it is the entire point of the split: a compromised operator can
 * spend up to the cap the controller already set, and cannot raise that cap, redirect the treasury,
 * or reactivate an agent the controller has stopped.
 *
 * **Policy defaults to deny.** A freshly registered agent can spend nothing until its controller
 * sets a policy for a specific token. Defaulting to "unlimited until configured" would mean every
 * agent has a window between registration and configuration in which it is unbounded — and windows
 * like that are exactly what gets exploited. Being explicit costs one transaction.
 *
 * **Budgets are per agent, per token.** An agent authorised to move 100 USDC has not thereby been
 * authorised to move 100 units of anything else.
 */
contract AgentRegistry is Ownable {
    /**
     * @param controller Authority over this agent's configuration.
     * @param operator Key permitted to submit actions.
     * @param treasury Source of funds and destination for output.
     * @param metadataURI Off-chain descriptor — what the agent claims to do.
     * @param active Whether the router should accept actions for this agent.
     * @param registeredAt Block timestamp of registration.
     */
    struct Agent {
        address controller;
        address operator;
        address treasury;
        string metadataURI;
        bool active;
        uint64 registeredAt;
    }

    /**
     * @param maxPerAction Ceiling on a single action.
     * @param maxPerEpoch Ceiling on the sum of actions within one epoch.
     * @param epochDuration Length of an epoch in seconds. Zero means no policy has been set, which
     *        is why it doubles as the "configured" flag.
     */
    struct SpendPolicy {
        uint256 maxPerAction;
        uint256 maxPerEpoch;
        uint64 epochDuration;
    }

    error AgentRegistry__ZeroAddress();
    error AgentRegistry__UnknownAgent(uint256 agentId);
    error AgentRegistry__NotController(uint256 agentId, address caller);
    error AgentRegistry__NotOperator(uint256 agentId, address caller);
    error AgentRegistry__NotRouter(address caller);
    error AgentRegistry__AgentInactive(uint256 agentId);
    error AgentRegistry__NoPolicy(uint256 agentId, address token);
    error AgentRegistry__ExceedsPerAction(uint256 requested, uint256 allowed);
    error AgentRegistry__ExceedsPerEpoch(uint256 requested, uint256 remaining);
    error AgentRegistry__InvalidPolicy();

    event AgentRegistered(uint256 indexed agentId, address indexed controller, address indexed operator);
    event OperatorChanged(uint256 indexed agentId, address indexed previousOperator, address indexed newOperator);
    event TreasuryChanged(uint256 indexed agentId, address indexed previousTreasury, address indexed newTreasury);
    event ControllerTransferred(
        uint256 indexed agentId, address indexed previousController, address indexed newController
    );
    event MetadataChanged(uint256 indexed agentId, string metadataURI);
    event ActiveChanged(uint256 indexed agentId, bool active);
    event SpendPolicyChanged(
        uint256 indexed agentId, address indexed token, uint256 maxPerAction, uint256 maxPerEpoch, uint64 epochDuration
    );
    event ActionRouterChanged(address indexed previousRouter, address indexed newRouter);
    event SpendRecorded(uint256 indexed agentId, address indexed token, uint256 amount, uint256 epochTotal);

    /// @notice The only contract permitted to record spend against an agent's budget.
    address public actionRouter;

    uint256 private _nextAgentId = 1;

    mapping(uint256 agentId => Agent) private _agents;
    mapping(uint256 agentId => mapping(address token => SpendPolicy)) private _policies;
    mapping(uint256 agentId => mapping(address token => uint256)) private _spentInEpoch;
    mapping(uint256 agentId => mapping(address token => uint64)) private _currentEpoch;

    constructor(address initialOwner) Ownable(initialOwner) { }

    modifier onlyController(uint256 agentId) {
        _requireRegistered(agentId);
        if (_agents[agentId].controller != msg.sender) {
            revert AgentRegistry__NotController(agentId, msg.sender);
        }
        _;
    }

    /**
     * @notice Register a new agent. The caller becomes its controller.
     * @dev Registration alone grants no spending ability — see `setSpendPolicy`.
     * @return agentId Identifier for the new agent. Ids start at 1, so zero is never valid and can
     *         be used as a sentinel by callers.
     */
    function registerAgent(address operator, address treasury, string calldata metadataURI)
        external
        returns (uint256 agentId)
    {
        if (operator == address(0) || treasury == address(0)) revert AgentRegistry__ZeroAddress();

        agentId = _nextAgentId++;
        _agents[agentId] = Agent({
            controller: msg.sender,
            operator: operator,
            treasury: treasury,
            metadataURI: metadataURI,
            active: true,
            registeredAt: uint64(block.timestamp)
        });

        emit AgentRegistered(agentId, msg.sender, operator);
    }

    /// @notice Rotate the agent's hot key. The expected response to a suspected compromise.
    function setOperator(uint256 agentId, address operator) external onlyController(agentId) {
        if (operator == address(0)) revert AgentRegistry__ZeroAddress();
        address previous = _agents[agentId].operator;
        _agents[agentId].operator = operator;
        emit OperatorChanged(agentId, previous, operator);
    }

    function setTreasury(uint256 agentId, address treasury) external onlyController(agentId) {
        if (treasury == address(0)) revert AgentRegistry__ZeroAddress();
        address previous = _agents[agentId].treasury;
        _agents[agentId].treasury = treasury;
        emit TreasuryChanged(agentId, previous, treasury);
    }

    function setMetadataURI(uint256 agentId, string calldata metadataURI) external onlyController(agentId) {
        _agents[agentId].metadataURI = metadataURI;
        emit MetadataChanged(agentId, metadataURI);
    }

    /// @notice Stop or resume an agent. Deactivation takes effect immediately for the router.
    function setActive(uint256 agentId, bool active) external onlyController(agentId) {
        _agents[agentId].active = active;
        emit ActiveChanged(agentId, active);
    }

    /// @notice Hand control to a new controller. Does not alter the operator or treasury.
    function transferControl(uint256 agentId, address newController) external onlyController(agentId) {
        if (newController == address(0)) revert AgentRegistry__ZeroAddress();
        address previous = _agents[agentId].controller;
        _agents[agentId].controller = newController;
        emit ControllerTransferred(agentId, previous, newController);
    }

    /**
     * @notice Set what this agent may spend of one token.
     * @dev Changing a policy does not reset the amount already spent in the current epoch. Lowering
     *      a cap mid-epoch therefore takes effect immediately rather than granting a fresh budget,
     *      which is the safe direction for the operation a controller reaches for in an incident.
     */
    function setSpendPolicy(
        uint256 agentId,
        address token,
        uint256 maxPerAction,
        uint256 maxPerEpoch,
        uint64 epochDuration
    ) external onlyController(agentId) {
        if (token == address(0)) revert AgentRegistry__ZeroAddress();
        if (epochDuration == 0) revert AgentRegistry__InvalidPolicy();
        if (maxPerAction > maxPerEpoch) revert AgentRegistry__InvalidPolicy();

        _policies[agentId][token] =
            SpendPolicy({ maxPerAction: maxPerAction, maxPerEpoch: maxPerEpoch, epochDuration: epochDuration });

        emit SpendPolicyChanged(agentId, token, maxPerAction, maxPerEpoch, epochDuration);
    }

    /// @notice Point the registry at the router allowed to record spend.
    function setActionRouter(address router) external onlyOwner {
        if (router == address(0)) revert AgentRegistry__ZeroAddress();
        address previous = actionRouter;
        actionRouter = router;
        emit ActionRouterChanged(previous, router);
    }

    /**
     * @notice Authorise one action and charge it against the agent's budget.
     * @dev Router-only, and state-changing by design. Splitting this into a `check` view plus a
     *      separate `record` would create a window in which two actions both pass the check before
     *      either records, letting an agent exceed its epoch cap. Checking and charging in one
     *      call closes that.
     */
    function authorizeSpend(uint256 agentId, address operator, address token, uint256 amount) external {
        if (msg.sender != actionRouter) revert AgentRegistry__NotRouter(msg.sender);
        _requireRegistered(agentId);

        Agent storage agent = _agents[agentId];
        if (!agent.active) revert AgentRegistry__AgentInactive(agentId);
        if (agent.operator != operator) revert AgentRegistry__NotOperator(agentId, operator);

        SpendPolicy memory policy = _policies[agentId][token];
        if (policy.epochDuration == 0) revert AgentRegistry__NoPolicy(agentId, token);
        if (amount > policy.maxPerAction) revert AgentRegistry__ExceedsPerAction(amount, policy.maxPerAction);

        uint64 epoch = uint64(block.timestamp / policy.epochDuration);
        uint256 spent = _currentEpoch[agentId][token] == epoch ? _spentInEpoch[agentId][token] : 0;

        if (spent + amount > policy.maxPerEpoch) {
            revert AgentRegistry__ExceedsPerEpoch(amount, policy.maxPerEpoch - spent);
        }

        uint256 newTotal = spent + amount;
        _spentInEpoch[agentId][token] = newTotal;
        _currentEpoch[agentId][token] = epoch;

        emit SpendRecorded(agentId, token, amount, newTotal);
    }

    // --- views ---

    function agentOf(uint256 agentId) external view returns (Agent memory) {
        _requireRegistered(agentId);
        return _agents[agentId];
    }

    function policyOf(uint256 agentId, address token) external view returns (SpendPolicy memory) {
        return _policies[agentId][token];
    }

    /// @notice Amount spent of `token` in the epoch that is current *now*. Reads zero once an epoch rolls.
    function spentThisEpoch(uint256 agentId, address token) external view returns (uint256) {
        SpendPolicy memory policy = _policies[agentId][token];
        if (policy.epochDuration == 0) return 0;
        uint64 epoch = uint64(block.timestamp / policy.epochDuration);
        return _currentEpoch[agentId][token] == epoch ? _spentInEpoch[agentId][token] : 0;
    }

    /// @notice Whether `operator` may currently submit actions for `agentId`.
    function isAuthorizedOperator(uint256 agentId, address operator) external view returns (bool) {
        Agent memory agent = _agents[agentId];
        return agent.controller != address(0) && agent.active && agent.operator == operator;
    }

    /// @notice Total agents ever registered. Ids run from 1 to this value inclusive.
    function agentCount() external view returns (uint256) {
        return _nextAgentId - 1;
    }

    function _requireRegistered(uint256 agentId) private view {
        if (_agents[agentId].controller == address(0)) revert AgentRegistry__UnknownAgent(agentId);
    }
}
