/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.21;
pragma experimental ABIEncoderV2;

import "../IAssetProxy.sol";
import "../../../utils/LibBytes/LibBytes.sol";
import "../../../utils/Authorizable/Authorizable.sol";
import "../../../tokens/ERC721Token/ERC721Token.sol";

contract ERC721Proxy is
    LibBytes,
    Authorizable,
    IAssetProxy
{

    uint8 constant PROXY_ID = 2;

    /// @dev Transfers ERC721 tokens. Either succeeds or throws.
    /// @param assetMetadata ERC721-encoded byte array
    /// @param from Address to transfer asset from.
    /// @param to Address to transfer asset to.
    /// @param amount Amount of asset to transfer.
    function transferFrom(
        bytes assetMetadata,
        address from,
        address to,
        uint256 amount)
        external
        onlyAuthorized
    {
        transferFromInternal(
            assetMetadata,
            from,
            to,
            amount
        );
    }

    /// @dev Makes multiple transfers of assets. Either succeeds or throws.
    /// @param assetMetadata Array of byte arrays encoded for the respective asset proxy.
    /// @param from Array of addresses to transfer assets from.
    /// @param to Array of addresses to transfer assets to.
    /// @param amounts Array of amounts of assets to transfer.
    function batchTransferFrom(
        bytes[] memory assetMetadata,
        address[] memory from,
        address[] memory to,
        uint256[] memory amounts)
        public
        onlyAuthorized
    {
        for (uint256 i = 0; i < assetMetadata.length; i++) {
            transferFromInternal(
                assetMetadata[i],
                from[i],
                to[i],
                amounts[i]
            );
        }
    }

    /// @dev Internal version of `transferFrom`.
    /// @param assetMetadata ERC20-encoded byte array.
    /// @param from Address to transfer asset from.
    /// @param to Address to transfer asset to.
    /// @param amount Amount of asset to transfer.
    function transferFromInternal(
        bytes memory assetMetadata,
        address from,
        address to,
        uint256 amount)
        internal
    {
        // Data must be intended for this proxy.
        require(uint8(assetMetadata[0]) == PROXY_ID);

        // There exists only 1 of each token.
        require(amount == 1);

        // Decode metadata.
        require(assetMetadata.length == 53);
        address token = readAddress(assetMetadata, 1);
        uint256 tokenId = readUint256(assetMetadata, 21);

        // Transfer token.
        // Either succeeds or throws.
        // @TODO: Call safeTransferFrom if there is additional
        //        data stored in `assetMetadata`.
        ERC721Token(token).transferFrom(from, to, tokenId);
    }

    /// @dev Gets the proxy id associated with the proxy address.
    /// @return Proxy id.
    function getProxyId()
        external
        view
        returns (uint8)
    {
        return PROXY_ID;
    }
}
