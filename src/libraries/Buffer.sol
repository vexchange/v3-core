// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
pragma solidity ^0.8.0;

library Buffer {
    // The buffer is a circular storage structure with 2048 (2 ** 11) slots.
    uint16 public constant SIZE = 2048;

    /**
     * @dev Returns the index of the element before the one pointed by `index`.
     */
    function prev(uint16 index) internal pure returns (uint16) {
        return sub(index, 1);
    }

    /**
     * @dev Returns the index of the element after the one pointed by `index`.
     */
    function next(uint16 index) internal pure returns (uint16) {
        return add(index, 1);
    }

    /**
     * @dev Returns the index of an element `offset` slots after the one pointed by `index`.
     */
    function add(uint16 index, uint16 offset) internal pure returns (uint16) {
        unchecked {
            return (index + offset) % SIZE;
        }
    }

    /**
     * @dev Returns the index of an element `offset` slots before the one pointed by `index`.
     */
    function sub(uint16 index, uint16 offset) internal pure returns (uint16) {
        unchecked {
            return (index + SIZE - offset) % SIZE;
        }
    }
}
