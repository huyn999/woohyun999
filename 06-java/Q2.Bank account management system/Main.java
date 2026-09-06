public class Main {
    public static void main(String[] args) {
        BankManager bankManager = new BankManager();

        try {
            // Initial account list print
            System.out.println("== Initial Account List ==");
            bankManager.printAllAccounts();

            // Adding accounts
            SavingsAccount savingsAccount = new SavingsAccount("ACC12345", 1000, 5.0);
            CheckingAccount checkingAccount = new CheckingAccount("ACC67890", 500, 100);

            bankManager.addAccount(savingsAccount);
            bankManager.addAccount(checkingAccount);
            System.out.println("== Accounts Added ==");
            bankManager.printAllAccounts();

            // Deposit test
            System.out.println("== Deposit Test ==");
            bankManager.deposit("ACC12345", 200);
            System.out.println("Balance after depositing 200 into ACC12345: " + bankManager.findAccount("ACC12345").getBalance());
            bankManager.deposit("ACC67890", 150);
            System.out.println("Balance after depositing 150 into ACC67890: " + bankManager.findAccount("ACC67890").getBalance());

            // Withdrawal test
            System.out.println("== Withdrawal Test ==");
            bankManager.withdraw("ACC12345", 100);
            System.out.println("Balance after withdrawing 100 from ACC12345: " + bankManager.findAccount("ACC12345").getBalance());

            try {
                bankManager.withdraw("ACC67890", 600); // Attempting to overdraw
                System.out.println("Balance after withdrawing 600 from ACC67890: " + bankManager.findAccount("ACC67890").getBalance());
            } catch (InsufficientBalanceException e) {
                System.out.println("Error: " + e.getMessage());
            }

            // Interest application test
            System.out.println("== Interest Application Test ==");
            savingsAccount.applyInterest();
            System.out.println("Balance after applying interest to ACC12345: " + bankManager.findAccount("ACC12345").getBalance());

            // Print all accounts
            System.out.println("== All Accounts ==");
            bankManager.printAllAccounts();

            // Duplicate account test
            System.out.println("== Duplicate Account Test ==");
            try {
                bankManager.addAccount(savingsAccount); // Trying to add a duplicate account
            } catch (DuplicateAccountException e) {
                System.out.println("Error: " + e.getMessage());
            }

            // Account search test
            System.out.println("== Account Search Test ==");
            try {
                BankAccount foundAccount = bankManager.findAccount("ACC12345");
                System.out.println("Found Account: " + foundAccount.getAccountNumber() + ", Balance: " + foundAccount.getBalance());
            } catch (AccountNotFoundException e) {
                System.out.println("Error: " + e.getMessage());
            }

            // Invalid account search test
            try {
                bankManager.findAccount("ACC99999"); // Searching for a non-existent account
            } catch (AccountNotFoundException e) {
                System.out.println("Error: " + e.getMessage());
            }

        } catch (DuplicateAccountException e) {
            System.out.println("Error: " + e.getMessage());
        } catch (AccountNotFoundException e) {
            System.out.println("Error: " + e.getMessage());
        } catch (InsufficientBalanceException e) {
            System.out.println("Error: " + e.getMessage());
        }
    }
}
