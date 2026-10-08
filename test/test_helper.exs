ExUnit.start()

Mox.defmock(Messaging.Chat.RepoMock, for: Messaging.Chat.Repo)
Mox.defmock(Messaging.Chat.PermissionsClientMock, for: Messaging.Chat.PermissionsClient)
Mox.defmock(Messaging.Chat.UsersClientMock, for: Messaging.Chat.UsersClient)
Mox.defmock(Messaging.Chat.MentionsClientMock, for: Messaging.Chat.MentionsClient)
Mox.defmock(Messaging.Auth.TicketStoreMock, for: Messaging.Auth.TicketStore)
