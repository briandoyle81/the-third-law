// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

error ContractPaused();
error NotEnoughFunds();
error NotEnoughTorpedoes();
error NotEnoughMines();
error NotYourTurn();
error NotYourGame();
error GameNotActive();
error AlreadyRegistered();
error NotRegistered(address _playerAddress);
error NotInvited(uint _gameId);

int constant QUADRANT_SIZE = 30;
int constant START_DISTANCE = 20;
uint constant ASTEROID_SIZE = 10; // Manhattan distance

enum LeftOrRight {
    None,
    Left,
    Right
}

enum UpOrDown {
    None,
    Up,
    Down
}

enum Action {
    None,
    FireTorpedo,
    DropMine
}

enum Status {
    NotStarted,
    Player1Destroyed,
    Player2Destroyed,
    Player1Fled,
    Player2Fled,
    Draw,
    Active,
    Over
}

contract TheThirdLaw is Ownable {
    uint public gameCost = 0.001 ether;
    uint public feePercent = 10;
    uint public feeBalance = 0;

    uint public maxTorpedoes = 5;
    uint public maxMines = 5;
    uint public torpedoFuel = 10;
    uint public mineRange = 2;
    int public torpedoAccel = 3;

    // 5 minutes in milliseconds
    uint public turnTimeout = 5 * 60 * 1000;

    bool public active = true;

    // Super savvy players can find this and use it to decide whether or not
    // to join an open game
    uint openGameId = 0;

    // If a miner wants to manipulate a block just to go first or pick start
    // that's fine.
    uint insecureSeed = 8291981;

    mapping(address => Player) public players;

    Game[] public games;

    event InviteToGame(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );
    event JoinGame(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    event OpenGameCreated(
        address indexed _player1Address,
        uint indexed _gameId
    );
    event OpenGameJoined(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    event GameStarted(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    event GameOver(
        address indexed _player1Address,
        address indexed _player2Address,
        uint indexed _gameId
    );

    struct Game {
        uint id;
        address player1Address;
        address player2Address;
        Ship player1Ship;
        Ship player2Ship;
        Status status;
        uint value; // Amount to be paid to victor, or split if there is a tie
        address currentPlayer; // Set to None if game not started or is over
        uint lastTurnTimestamp;
    }

    struct Player {
        address ownerAddress;
        uint[] gameIds;
        uint[] inviteIds;
        uint victories; // Enemy was destroyed
        uint defaultVictories; // Enemy was forced to flee
        uint defaultLosses; // Player was forced to flee
        uint draws; // Both players ran out of weapons
        uint losses; // Player was destroyed
        uint eloRating;
        uint currentShipId;
    }

    struct Ship {
        address ownerAddress;
        Position position;
        Velocity velocity;
        uint remainingTorpedoes;
        uint remainingMines;
        Torpedo[] torpedoes; // Added this line
        Mine[] mines; // Added this line
    }

    struct Torpedo {
        Position position;
        Velocity velocity;
        uint remainingFuel;
    }

    struct Mine {
        Position position;
    }

    struct Position {
        int row;
        int col;
    }

    struct Velocity {
        int row;
        int col;
    }

    constructor() {
        games.push();
    }

    // PUBLIC

    function inviteToGame(address _player2Address) public payable isActive {
        if (msg.value != gameCost) revert NotEnoughFunds();

        if (players[msg.sender].ownerAddress == address(0)) {
            _registerPlayer();
        }

        uint gameId = games.length;
        games.push();
        games[gameId].id = gameId;
        games[gameId].player1Address = msg.sender;
        games[gameId].player2Address = _player2Address;
        games[gameId].value = msg.value;
        players[msg.sender].gameIds.push(gameId);
        players[_player2Address].gameIds.push(gameId);
        players[_player2Address].inviteIds.push(gameId); // TODO: This is probably not the best way to handle this

        emit InviteToGame(msg.sender, _player2Address, gameId);
    }

    function acceptInvite(uint _gameId) public payable {
        if (msg.value != gameCost) revert NotEnoughFunds();

        if (players[msg.sender].ownerAddress == address(0)) {
            _registerPlayer();
        }

        if (games[_gameId].player2Address != msg.sender)
            revert NotInvited(_gameId);

        games[_gameId].value += msg.value;

        _startGame(_gameId);

        emit JoinGame(games[_gameId].player1Address, msg.sender, _gameId);
    }

    // Prevent spam by refunding the inviter's fee to the game contract if
    // the invite is rejected.
    function rejectInvite(uint _gameId) public {
        if (games[_gameId].player2Address != msg.sender)
            revert NotInvited(_gameId);

        feeBalance += games[_gameId].value;
        games[_gameId].value = 0;

        games[_gameId].status = Status.Over;
    }

    function takeTurn(
        uint _gameId,
        LeftOrRight _leftOrRight,
        UpOrDown _upOrDown,
        Action _action
    ) public {
        Game storage game = games[_gameId];

        if (game.status != Status.Active) revert GameNotActive();
        if (game.currentPlayer != msg.sender) revert NotYourTurn();

        Ship storage ship;
        Ship storage enemyShip;

        if (game.currentPlayer == game.player1Address) {
            ship = game.player1Ship;
            enemyShip = game.player2Ship;
        } else {
            ship = game.player2Ship;
            enemyShip = game.player1Ship;
        }

        if (_leftOrRight == LeftOrRight.Left) {
            ship.velocity.col -= 1;
        } else if (_leftOrRight == LeftOrRight.Right) {
            ship.velocity.col += 1;
        }

        if (_upOrDown == UpOrDown.Up) {
            ship.velocity.row -= 1;
        } else if (_upOrDown == UpOrDown.Down) {
            ship.velocity.row += 1;
        }

        if (_action == Action.FireTorpedo) {
            if (ship.remainingTorpedoes == 0) revert NotEnoughTorpedoes();
            ship.remainingTorpedoes -= 1;
            ship.torpedoes.push(
                Torpedo(
                    Position(ship.position.row, ship.position.col),
                    Velocity(ship.velocity.row, ship.velocity.col),
                    torpedoFuel
                )
            );
        } else if (_action == Action.DropMine) {
            if (ship.remainingMines == 0) revert NotEnoughMines();
            ship.remainingMines -= 1;
            ship.mines.push(
                Mine(Position(ship.position.row, ship.position.col))
            );
        }

        _moveShip(ship);
        _checkForFleeingBoard(game, ship);
        _checkForAsteroidCollision(game, ship);
        _checkForMineCollision(game, ship, enemyShip.mines);
        _moveTorpedoesTowardsEnemy(game, enemyShip, ship.torpedoes);
        game.lastTurnTimestamp = block.timestamp;

        // Switch the current player
        if (game.currentPlayer == game.player1Address) {
            game.currentPlayer = game.player2Address;
        } else {
            game.currentPlayer = game.player1Address;
        }
    }

    // If it's been 5 minutes since the last player's turn, then either player
    // can end the game in a draw

    function endGame(uint _gameId) public {
        // Only one of the players in the game can call this function
        if (
            games[_gameId].player1Address != msg.sender &&
            games[_gameId].player2Address != msg.sender
        ) revert NotYourGame();

        _endGame(_gameId, Status.Draw);
    }

    // If it's been 5 minutes since the last player's turn, the other player
    // can force their opponent to move with no input
    // TODO: CRITICAL

    // INTERNAL

    function _moveShip(Ship storage _ship) internal {
        _ship.position.row += _ship.velocity.row;
        _ship.position.col += _ship.velocity.col;
    }

    function _moveTorpedoesTowardsEnemy(
        Game storage _game,
        Ship storage _enemyShip,
        Torpedo[] storage _torpedoes
    ) internal {
        for (uint i = 0; i < _torpedoes.length; i++) {
            if (_torpedoes[i].remainingFuel == 0) {
                continue;
            } else {
                _torpedoes[i].remainingFuel -= 1;
                Position memory nextTorpedoPosition = Position(
                    _torpedoes[i].position.row + _torpedoes[i].velocity.row,
                    _torpedoes[i].position.col + _torpedoes[i].velocity.col
                );
                // If the nextTorpedoPosition is within torpedoAccel of the enemy ship,
                // then the torpedo has hit the enemy ship and the game is over.
                // We have to check row and col separately because the movement is
                // constrained to torpedoAccel in each direction.
                if (
                    abs(nextTorpedoPosition.row - _enemyShip.position.row) <=
                    torpedoAccel &&
                    abs(nextTorpedoPosition.col - _enemyShip.position.col) <=
                    torpedoAccel
                ) {
                    // This player has hit the enemy ship and won
                    if (_enemyShip.ownerAddress == _game.player1Address) {
                        _endGame(_game.id, Status.Player1Destroyed);
                    } else {
                        _endGame(_game.id, Status.Player2Destroyed);
                    }
                }

                // Otherwise, change the nextTorpedoPosition's row and col
                // by a maximun of torpedoAccel in each direction so that it's
                // as close to the enemy ship as possible

                // First, check if the torpedo is above or below the enemy ship

                // If the torpedo is above the enemy ship, then the torpedo's
                // row should be decreased by a maximum of torpedoAccel
                if (nextTorpedoPosition.row < _enemyShip.position.row) {
                    if (
                        nextTorpedoPosition.row + torpedoAccel <
                        _enemyShip.position.row
                    ) {
                        nextTorpedoPosition.row += torpedoAccel;
                    } else {
                        nextTorpedoPosition.row = _enemyShip.position.row;
                    }
                }
                // If the torpedo is below the enemy ship, then the torpedo's
                // row should be increased by a maximum of torpedoAccel
                else if (nextTorpedoPosition.row > _enemyShip.position.row) {
                    if (
                        nextTorpedoPosition.row - torpedoAccel >
                        _enemyShip.position.row
                    ) {
                        nextTorpedoPosition.row -= torpedoAccel;
                    } else {
                        nextTorpedoPosition.row = _enemyShip.position.row;
                    }
                }

                // Next, check if the torpedo is to the left or right of the enemy ship

                // If the torpedo is to the left of the enemy ship, then the torpedo's
                // col should be decreased by a maximum of torpedoAccel
                if (nextTorpedoPosition.col < _enemyShip.position.col) {
                    if (
                        nextTorpedoPosition.col + torpedoAccel <
                        _enemyShip.position.col
                    ) {
                        nextTorpedoPosition.col += torpedoAccel;
                    } else {
                        nextTorpedoPosition.col = _enemyShip.position.col;
                    }
                }
                // If the torpedo is to the right of the enemy ship, then the torpedo's
                // col should be increased by a maximum of torpedoAccel
                else if (nextTorpedoPosition.col > _enemyShip.position.col) {
                    if (
                        nextTorpedoPosition.col - torpedoAccel >
                        _enemyShip.position.col
                    ) {
                        nextTorpedoPosition.col -= torpedoAccel;
                    } else {
                        nextTorpedoPosition.col = _enemyShip.position.col;
                    }
                }

                // Update the torpedo's velocity to match the acceleration changes
                _torpedoes[i].velocity = Velocity(
                    nextTorpedoPosition.row - _torpedoes[i].position.row,
                    nextTorpedoPosition.col - _torpedoes[i].position.col
                );

                _torpedoes[i].position = nextTorpedoPosition;

                // If the torpedo has hit an asteroid, then the torpedo is destroyed
                if (
                    _manhattanDistance(nextTorpedoPosition, Position(0, 0)) <=
                    ASTEROID_SIZE
                ) {
                    _torpedoes[i].remainingFuel = 0;
                }
            }
        }
    }

    function _checkForAsteroidCollision(
        Game storage _game,
        Ship storage _ship
    ) internal {
        if (
            _manhattanDistance(_ship.position, Position(0, 0)) <= ASTEROID_SIZE
        ) {
            // This player has hit an asteroid and lost
            if (_ship.ownerAddress == _game.player1Address) {
                _endGame(_game.id, Status.Player1Destroyed);
            } else {
                _endGame(_game.id, Status.Player2Destroyed);
            }
        }
    }

    function _checkForMineCollision(
        Game storage _game,
        Ship storage _ship,
        Mine[] storage _enemyMines
    ) internal {
        for (uint i = 0; i < _enemyMines.length; i++) {
            if (
                _manhattanDistance(_ship.position, _enemyMines[i].position) <=
                mineRange
            ) {
                // This player has hit a mine and lost
                if (_ship.ownerAddress == _game.player1Address) {
                    _endGame(_game.id, Status.Player1Destroyed);
                } else {
                    _endGame(_game.id, Status.Player2Destroyed);
                }
            }
        }
    }

    function _checkForFleeingBoard(
        Game storage _game,
        Ship storage _ship
    ) internal {
        if (
            abs(_ship.position.row) > QUADRANT_SIZE ||
            abs(_ship.position.col) > QUADRANT_SIZE
        ) {
            // This player has fled the board and lost
            if (_ship.ownerAddress == _game.player1Address) {
                _endGame(_game.id, Status.Player1Fled);
            } else {
                _endGame(_game.id, Status.Player2Fled);
            }
        }
    }

    // THIS MUST BE AUDITED!!!
    function _endGame(uint _gameId, Status _status) internal {
        Game storage game = games[_gameId];
        game.status = _status;
        game.currentPlayer = address(0);

        if (_status == Status.Player1Destroyed) {
            players[game.player2Address].victories += 1;
            players[game.player1Address].losses += 1;

            // Pay the victor
            uint payout = game.value;
            game.value = 0;
            payable(game.player2Address).transfer(payout);
        } else if (_status == Status.Player2Destroyed) {
            players[game.player1Address].victories += 1;
            players[game.player2Address].losses += 1;

            // Pay the victor
            uint payout = game.value;
            game.value = 0;
            payable(game.player1Address).transfer(payout);
            game.value = 0;
        } else if (_status == Status.Player1Fled) {
            players[game.player2Address].defaultVictories += 1;
            players[game.player1Address].defaultLosses += 1;

            uint balance = game.value;
            game.value = 0;
            // Pay the victor 75% of the game value
            uint payout = (balance * 75) / 100;
            payable(game.player2Address).transfer(payout);
            balance -= payout;

            // Add the remaining 25% to the contract's fee balance
            feeBalance += balance;
        } else if (_status == Status.Player2Fled) {
            players[game.player1Address].defaultVictories += 1;
            players[game.player2Address].defaultLosses += 1;

            uint balance = game.value;
            game.value = 0;
            // Pay the victor 75% of the game value
            uint payout = (balance * 75) / 100;
            payable(game.player1Address).transfer(payout);
            balance -= payout;

            // Add the remaining 25% to the contract's fee balance
            feeBalance += balance;
        } else if (_status == Status.Draw) {
            players[game.player1Address].draws += 1;
            players[game.player2Address].draws += 1;

            // Split the game value between the players
            uint balance = game.value;
            game.value = 0;
            // Pay each player 50% of the game value
            uint payout = balance / 2;
            payable(game.player1Address).transfer(payout);
            balance -= payout;
            payable(game.player2Address).transfer(balance);
        }

        emit GameOver(game.player1Address, game.player2Address, _gameId);
    }

    function _registerPlayer() internal {
        if (players[msg.sender].ownerAddress != address(0))
            revert AlreadyRegistered();
        players[msg.sender] = Player(
            msg.sender,
            new uint[](0),
            new uint[](0),
            0,
            0,
            0,
            0,
            0,
            1200,
            0
        );
    }

    function _startGame(uint _gameId) internal {
        Ship storage player1Ship = games[_gameId].player1Ship;
        Ship storage player2Ship = games[_gameId].player2Ship;

        // Player 1 starts on left side, can be top or bottom
        // They start on the top if the block number is even and on the bottom if it's odd
        int player1Row = int(block.number) % 2 == 0 ? int(1) : -1;

        player1Ship.ownerAddress = games[_gameId].player1Address;
        player1Ship.position = Position(
            START_DISTANCE * player1Row,
            -START_DISTANCE
        );
        player1Ship.velocity = Velocity(0, 0);
        player1Ship.remainingTorpedoes = maxTorpedoes;
        player1Ship.remainingMines = maxMines;

        // Player 2 starts on right side, can be top or bottom, based on timestamp
        int player2Row = int(block.timestamp) % 2 == 0 ? int(1) : -1;

        player2Ship.ownerAddress = games[_gameId].player2Address;
        player2Ship.position = Position(
            START_DISTANCE * player2Row,
            START_DISTANCE
        );
        player2Ship.velocity = Velocity(0, 0);
        player2Ship.remainingTorpedoes = maxTorpedoes;
        player2Ship.remainingMines = maxMines;

        // Assuming torpedoes and mines arrays start empty, there's no need to initialize them

        // Flip a coin and set the starting player
        if (block.prevrandao % 2 == 0) {
            games[_gameId].currentPlayer = games[_gameId].player1Address;
        } else {
            games[_gameId].currentPlayer = games[_gameId].player2Address;
        }

        games[_gameId].status = Status.Active;

        // Take the fee from the game value and add it to the contract's fee balance
        uint fee = (games[_gameId].value * feePercent) / 100;
        feeBalance += fee;
        games[_gameId].value -= fee;

        emit GameStarted(
            games[_gameId].player1Address,
            games[_gameId].player2Address,
            _gameId
        );
    }

    // UTILS

    function _manhattanDistance(
        Position memory _position1,
        Position memory _position2
    ) internal pure returns (uint) {
        return
            uint(
                abs(_position1.row - _position2.row) +
                    abs(_position1.col - _position2.col)
            );
    }

    function abs(int _x) internal pure returns (int) {
        if (_x < 0) {
            return -_x;
        } else {
            return _x;
        }
    }

    // VIEWS

    // TODO: Do these need some kind of pagination?
    // function getGames() public view returns (Game[] memory) {
    //     return games;
    // }

    function getGamesForPlayer(
        address _playerAddress
    ) public view returns (Game[] memory) {
        uint[] memory gameIds = players[_playerAddress].gameIds;
        Game[] memory playerGames = new Game[](gameIds.length);
        for (uint i = 0; i < gameIds.length; i++) {
            playerGames[i] = games[gameIds[i]];
        }
        return playerGames;
    }

    function getPlayer(
        address _playerAddress
    ) public view returns (Player memory) {
        return players[_playerAddress];
    }

    function getGame(uint _gameId) public view returns (Game memory) {
        return games[_gameId];
    }

    // MODIFIERS

    modifier isActive() {
        if (!active) revert ContractPaused();
        _;
    }

    // ADMIN

    function setGameCost(uint _gameCost) public onlyOwner {
        gameCost = _gameCost;
    }

    function setFeePercent(uint _feePercent) public onlyOwner {
        feePercent = _feePercent;
    }

    function setNumberTorpedoes(uint _maxTorpedoes) public onlyOwner {
        maxTorpedoes = _maxTorpedoes;
    }

    function setNumberMines(uint _maxMines) public onlyOwner {
        maxMines = _maxMines;
    }

    function setTorpedoFuel(uint _torpedoFuel) public onlyOwner {
        torpedoFuel = _torpedoFuel;
    }

    function setMineRange(uint _mineRange) public onlyOwner {
        mineRange = _mineRange;
    }

    function setTorpedoAccel(int _torpedoAccel) public onlyOwner {
        torpedoAccel = _torpedoAccel;
    }

    function pause() public onlyOwner {
        active = false;
    }

    function withdrawFee() public onlyOwner {
        payable(msg.sender).transfer(feeBalance);
        feeBalance = 0;
    }
}
