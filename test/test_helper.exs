ExUnit.start()

Mox.defmock(Messaging.Chat.RepoMock, for: Messaging.Chat.Repo)
Mox.defmock(Messaging.Chat.PermissionsStoreMock, for: Messaging.Chat.PermissionsStore)
Mox.defmock(Messaging.Chat.MentionResolverMock, for: Messaging.Chat.MentionResolver)
Mox.defmock(Messaging.Auth.TicketStoreMock, for: Messaging.Auth.TicketStore)
