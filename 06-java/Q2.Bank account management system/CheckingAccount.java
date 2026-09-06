public class CheckingAccount extends BankAccount {
    private double overdraftLimit;

    public CheckingAccount(String accountNumber, double initialBalance, double overdraftLimit)
    {
        super(accountNumber, initialBalance);
        this.overdraftLimit = overdraftLimit;
    }

    @Override
    public void withdraw(double amount) throws InsufficientBalanceException
    {
        if (amount > getBalance() + overdraftLimit)// overdraft limit 고려
        {
            throw new InsufficientBalanceException("has not enough balance.");
        }
        else
        {
            deposit(-amount);
            // private 필드인 balance를 사용하기 위해 부모 클래스의 withdraw()를 사용하게 되면 overdraftLimit이 고려되지 않아 오류

        }


    }
}
