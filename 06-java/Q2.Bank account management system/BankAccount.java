public class BankAccount {
    private String accountNumber;
    private double balance;

    public BankAccount(String accountNumber, double initialBalance) {
        this.accountNumber = accountNumber;
        this.balance = initialBalance;
    }

    public String getAccountNumber() {
        return accountNumber;
    }

    public double getBalance() {
        return balance;
    }

    public void deposit(double amount)
    {
            balance += amount;
    }

    public void withdraw(double amount) throws InsufficientBalanceException
    {
        if (amount > balance) {
            throw new InsufficientBalanceException("has not enough balance.");
        }
        else{
            balance -= amount;
        }

    }
}
