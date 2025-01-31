#[starknet::contract]
pub mod merkle_tree_hook {
    use alexandria_bytes::{Bytes, BytesTrait};
    use alexandria_math::pow;
    use hyperlane_starknet::contracts::client::mailboxclient_component::{
        MailboxclientComponent, MailboxclientComponent::MailboxClientInternalImpl
    };
    use hyperlane_starknet::contracts::hooks::libs::standard_hook_metadata::standard_hook_metadata::{
        StandardHookMetadata, VARIANT
    };
    use hyperlane_starknet::contracts::libs::merkle_lib::merkle_lib::{Tree, MerkleLib};
    use hyperlane_starknet::contracts::libs::message::{Message, MessageTrait};
    use hyperlane_starknet::interfaces::{
        IMailboxClientDispatcher, IMailboxClientDispatcherTrait, Types, IMerkleTreeHook,
        IPostDispatchHook, IMailboxClient, IMailboxDispatcher, IMailboxDispatcherTrait,
    };
    use hyperlane_starknet::utils::keccak256::{reverse_endianness, compute_keccak, ByteData};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::upgrades::{interface::IUpgradeable, upgradeable::UpgradeableComponent};
    use starknet::ContractAddress;
    type Index = usize;
    pub const TREE_DEPTH: u32 = 32;
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: MailboxclientComponent, storage: mailboxclient, event: MailboxclientEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;


    #[storage]
    struct Storage {
        tree: LegacyMap<Index, u256>,
        count: u32,
        #[substorage(v0)]
        mailboxclient: MailboxclientComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
    }


    pub mod Errors {
        pub const MESSAGE_NOT_DISPATCHING: felt252 = 'Message not dispatching';
        pub const INVALID_METADATA_VARIANT: felt252 = 'Invalid metadata variant';
        pub const MERKLE_TREE_FULL: felt252 = 'Merkle tree full';
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        InsertedIntoTree: InsertedIntoTree,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        MailboxclientEvent: MailboxclientComponent::Event,
    }


    #[derive(starknet::Event, Drop)]
    pub struct InsertedIntoTree {
        pub id: u256,
        pub index: u32
    }

    #[constructor]
    fn constructor(ref self: ContractState, _mailbox: ContractAddress, _owner: ContractAddress,) {
        self.mailboxclient.initialize(_mailbox);
        self.ownable.initializer(_owner);
    }


    #[abi(embed_v0)]
    impl IMerkleTreeHookImpl of IMerkleTreeHook<ContractState> {
        fn count(self: @ContractState) -> u32 {
            self.count.read()
        }

        fn root(self: @ContractState) -> u256 {
            self._root()
        }

        fn tree(self: @ContractState) -> Tree {
            Tree { branch: self._build_tree(), count: self.count.read().into() }
        }

        fn latest_checkpoint(self: @ContractState) -> (u256, u32) {
            (self._root(), self.count())
        }
    }

    #[abi(embed_v0)]
    impl IPostDispatchHookImpl of IPostDispatchHook<ContractState> {
        fn hook_type(self: @ContractState) -> Types {
            Types::MERKLE_TREE(())
        }
        fn supports_metadata(self: @ContractState, _metadata: Bytes) -> bool {
            _metadata.size() == 0 || StandardHookMetadata::variant(_metadata) == VARIANT.into()
        }

        fn post_dispatch(ref self: ContractState, _metadata: Bytes, _message: Message) {
            assert(self.supports_metadata(_metadata.clone()), Errors::INVALID_METADATA_VARIANT);
            self._post_dispatch(_metadata, _message);
        }

        fn quote_dispatch(ref self: ContractState, _metadata: Bytes, _message: Message) -> u256 {
            assert(self.supports_metadata(_metadata.clone()), Errors::INVALID_METADATA_VARIANT);
            self._quote_dispatch(_metadata, _message)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _post_dispatch(ref self: ContractState, _metadata: Bytes, _message: Message) {
            let (id, _) = MessageTrait::format_message(_message);
            assert(self.mailboxclient._is_latest_dispatched(id), Errors::MESSAGE_NOT_DISPATCHING);
            let index = self.count();
            self._insert(id);
            self.emit(InsertedIntoTree { id, index });
        }

        fn _insert(ref self: ContractState, mut _node: u256) {
            let MAX_LEAVES: u128 = pow(2_u128, TREE_DEPTH.into()) - 1;
            let mut count = self.count.read();
            assert(count.into() < MAX_LEAVES, Errors::MERKLE_TREE_FULL);
            self.count.write(count + 1);
            let mut cur_idx = 0;
            loop {
                if (cur_idx == TREE_DEPTH) {
                    break ();
                }
                if (count & 1 == 1) {
                    self._insert_into_storage(_node, cur_idx);
                    break ();
                }
                _node =
                    compute_keccak(
                        array![
                            ByteData { value: self.tree.read(cur_idx), is_address: false },
                            ByteData { value: _node, is_address: false }
                        ]
                            .span()
                    );
                count /= 2;
                cur_idx += 1;
            };
        }
        fn _root_with_ctx(self: @ContractState, _zeroes: Array<u256>) -> u256 {
            let mut cur_idx = 0;
            let index = self.count.read();
            let mut current = *_zeroes[0];
            loop {
                if (cur_idx == TREE_DEPTH) {
                    break ();
                }
                let ith_bit = self._get_ith_bit(index.into(), cur_idx);
                let next = self.tree.read(cur_idx);
                if (ith_bit == 1) {
                    current =
                        compute_keccak(
                            array![
                                ByteData { value: next, is_address: false },
                                ByteData { value: current, is_address: false }
                            ]
                                .span()
                        );
                } else {
                    current =
                        compute_keccak(
                            array![
                                ByteData { value: current, is_address: false },
                                ByteData { value: *_zeroes.at(cur_idx), is_address: false }
                            ]
                                .span()
                        );
                }
                cur_idx += 1;
            };
            current
        }
        fn _branch_root(
            self: @ContractState, _item: u256, _branch: Span<u256>, _index: u256
        ) -> u256 {
            let mut cur_idx = 0;
            let mut current = _item;
            loop {
                if (cur_idx == TREE_DEPTH) {
                    break ();
                }
                let ith_bit = self._get_ith_bit(_index, cur_idx);
                let next = *_branch.at(cur_idx);
                if (ith_bit == 1) {
                    current =
                        compute_keccak(
                            array![
                                ByteData { value: next, is_address: false },
                                ByteData { value: current, is_address: false }
                            ]
                                .span()
                        );
                } else {
                    current =
                        compute_keccak(
                            array![
                                ByteData { value: current, is_address: false },
                                ByteData { value: next, is_address: false }
                            ]
                                .span()
                        );
                }
                cur_idx += 1;
            };
            current
        }
        fn _root(self: @ContractState) -> u256 {
            self._root_with_ctx(self._zero_hashes())
        }
        fn _insert_into_storage(ref self: ContractState, _node: u256, _index: u32) {
            let mut cur_idx = _index;
            let mut next_node = 0;
            let mut current_node = 0;
            loop {
                if (cur_idx == self.count.read() + 1) {
                    break ();
                }
                if (cur_idx == _index) {
                    next_node = self.tree.read(cur_idx);
                    self.tree.write(cur_idx, _node);
                } else {
                    current_node = next_node;
                    next_node = self.tree.read(cur_idx);
                    self.tree.write(cur_idx, current_node);
                }
                cur_idx += 1;
            }
        }

        fn _build_tree(self: @ContractState) -> Array<u256> {
            let mut cur_idx = 0;
            let mut tree = array![];
            loop {
                if (cur_idx == self.count.read()) {
                    break ();
                }
                tree.append(self.tree.read(cur_idx));
                cur_idx += 1;
            };
            tree
        }

        fn _quote_dispatch(ref self: ContractState, _metadata: Bytes, _message: Message) -> u256 {
            0_u256
        }

        fn _get_ith_bit(self: @ContractState, _index: u256, i: u32) -> u256 {
            let mask = pow(2.into(), i.into());
            _index & mask / mask
        }

        fn _zero_hashes(self: @ContractState) -> Array<u256> {
            array![
                0x0000000000000000000000000000000000000000000000000000000000000000,
                0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5,
                0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30,
                0x21ddb9a356815c3fac1026b6dec5df3124afbadb485c9ba5a3e3398a04b7ba85,
                0xe58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344,
                0x0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d,
                0x887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968,
                0xffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83,
                0x9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af,
                0xcefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0,
                0xf9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5,
                0xf8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892,
                0x3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c,
                0xc1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb,
                0x5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc,
                0xda7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2,
                0x2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f,
                0xe1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a,
                0x5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0,
                0xb46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0,
                0xc65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2,
                0xf4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9,
                0x5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377,
                0x4df84f40ae0c8229d0d6069e5c8f39a7c299677a09d367fc7b05e3bc380ee652,
                0xcdc72595f74c7b1043d0e1ffbab734648c838dfb0527d971b602bc216c9619ef,
                0x0abf5ac974a1ed57f4050aa510dd9c74f508277b39d7973bb2dfccc5eeb0618d,
                0xb8cd74046ff337f0a7bf2c8e03e10f642c1886798d71806ab1e888d9e5ee87d0,
                0x838c5655cb21c6cb83313b5a631175dff4963772cce9108188b34ac87c81c41e,
                0x662ee4dd2dd7b2bc707961b1e646c4047669dcb6584f0d8d770daf5d7e7deb2e,
                0x388ab20e2573d171a88108e79d820e98f26c0b84aa8b2f4aa4968dbb818ea322,
                0x93237c50ba75ee485f4c22adf2f741400bdf8d6a9cc7df7ecae576221665d735,
                0x8448818bb4ae4562849e949e17ac16e0be16688e156b5cf15e098c627c0056a9
            ]
        }
    }
}
