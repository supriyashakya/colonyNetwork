/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity 0.5.8;
pragma experimental ABIEncoderV2;

import "../ERC20Extended.sol";
import "../IColony.sol";
import "../IColonyNetwork.sol";
import "../ITokenLocking.sol";
import "../PatriciaTree/PatriciaTreeProofs.sol";
import "../../lib/dappsys/math.sol";


contract FundingQueue is DSMath, PatriciaTreeProofs {

  // Constants
  uint256 constant FUNDING_MULTIPLE = WAD / 2;

  // Initialization data
  IColony colony;
  IColonyNetwork colonyNetwork;
  ITokenLocking tokenLocking;
  address token;

  constructor(address _colony) public {
    colony = IColony(_colony);
    colonyNetwork = IColonyNetwork(colony.getColonyNetwork());
    tokenLocking = ITokenLocking(colonyNetwork.getTokenLocking());
    token = colony.getToken();
  }

  // Data structures
  enum ProposalState { Inactive, Active, Completed, Cancelled }

  struct Proposal {
    ProposalState state;
    address creator;
    address token;
    uint256 domainSkillId;
    uint256 fromPot;
    uint256 toPot;
    uint256 totalRequested;
    uint256 totalPaid;
    uint256 lastUpdated;
    uint256 totalSupport;
  }

  // Storage
  uint256 head;
  uint256 proposalCount;
  mapping (uint256 => Proposal) proposals;
  mapping (uint256 => uint256) queue;
  mapping (uint256 => mapping (address => uint256)) supporters;

  // Public functions

  function createBasicProposal(
    uint256 _domainId,
    uint256 _fromChildSkillIndex,
    uint256 _toChildSkillIndex,
    uint256 _fromPot,
    uint256 _toPot,
    uint256 _totalRequested,
    address _token
  )
    public
  {
    uint256 fromDomain = colony.getDomainFromFundingPot(_fromPot);
    uint256 toDomain = colony.getDomainFromFundingPot(_toPot);

    uint256 domainSkillId = colony.getDomain(_domainId).skillId;
    uint256 fromSkillId = colony.getDomain(fromDomain).skillId;
    uint256 toSkillId = colony.getDomain(toDomain).skillId;

    require(
      domainSkillId == fromSkillId ||
      fromSkillId == colonyNetwork.getChildSkillId(domainSkillId, _fromChildSkillIndex),
      "funding-queue-from-bad-inheritence"
    );
    require(
      domainSkillId == toSkillId ||
      toSkillId == colonyNetwork.getChildSkillId(domainSkillId, _toChildSkillIndex),
      "funding-queue-to-bad-inheritence"
    );

    proposals[++proposalCount] = Proposal(
      ProposalState.Active, msg.sender, _token, domainSkillId, _fromPot, _toPot, _totalRequested, 0, now, 0
    );
  }

  function backBasicProposal(
    uint256 _proposalId,
    uint256 _newLocation,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  )
    public
  {
    require(supporters[_proposalId][msg.sender] == 0, "funding-queue-already-supported");
    uint256 userReputation = checkReputation(_proposalId, msg.sender, _key, _value, _branchMask, _siblings);

    Proposal storage proposal = proposals[_proposalId];
    proposal.totalSupport = add(proposal.totalSupport, userReputation);
    supporters[_proposalId][msg.sender] = userReputation;

    if (_newLocation == 0) {
      require(proposals[queue[head]].totalSupport < proposal.totalSupport, "funding-queue-bad-location");
      queue[_proposalId] = queue[head];
      head = _proposalId;
    } else {
      require(proposals[_newLocation].totalSupport >= proposal.totalSupport, "funding-queue-bad-location");
      require(proposals[queue[_newLocation]].totalSupport < proposal.totalSupport, "funding-queue-bad-location");
      queue[_proposalId] = queue[_newLocation];
      queue[_newLocation] = _newLocation;
    }
  }

  function pingProposal(
    uint256 _proposalId,
    uint256 _permissionDomainId,
    uint256 _toChildSkillIndex,
    uint256 _fromChildSkillIndex,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  )
    public
  {
    Proposal storage proposal = proposals[_proposalId];

    uint256 totalDomainRep = checkReputation(_proposalId, address(0x0), _key, _value, _branchMask, _siblings);
    uint256 backingPercent = wdiv(proposal.totalSupport, totalDomainRep);
    uint256 elapsedPeriods = wdiv(now - proposal.lastUpdated, 7 days);

    uint256 fromPotBalance = colony.getFundingPotBalance(proposal.fromPot, token);
    uint256 fundingPerPeriod = wmul(fromPotBalance, wmul(backingPercent, FUNDING_MULTIPLE));
    uint256 fundingToTransfer = wmul(fundingPerPeriod, elapsedPeriods);

    proposal.lastUpdated = now;

    colony.moveFundsBetweenPots(
      _permissionDomainId,
      _toChildSkillIndex,
      _fromChildSkillIndex,
      proposal.fromPot,
      proposal.toPot,
      fundingToTransfer,
      proposal.token
    );
  }

  // Public view functions

  function getProposalCount() public view returns (uint256) {
    return proposalCount;
  }

  function getProposal(uint256 _id) public view returns (Proposal memory proposal) {
    return proposals[_id];
  }

  // Internal functions

  function checkReputation(
    uint256 _proposalId,
    address _who,
    bytes memory _key,
    bytes memory _value,
    uint256 _branchMask,
    bytes32[] memory _siblings
  )
    internal view returns (uint256)
  {
    bytes32 impliedRoot = getImpliedRootHashKey(_key, _value, _branchMask, _siblings);
    require(colonyNetwork.getReputationRootHash() == impliedRoot, "funding-queue-invalid-root-hash");

    uint256 reputationValue;
    address keyColonyAddress;
    uint256 keySkill;
    address keyUserAddress;

    assembly {
      reputationValue := mload(add(_value, 32))
      keyColonyAddress := mload(add(_key, 20))
      keySkill := mload(add(_key, 52))
      keyUserAddress := mload(add(_key, 72))
    }

    require(keyColonyAddress == address(colony), "funding-queue-invalid-colony-address");
    require(keySkill == proposals[_proposalId].domainSkillId, "funding-queue-invalid-skill-id");
    require(keyUserAddress == _who, "funding-queue-invalid-user-address");

    return reputationValue;
  }
}
